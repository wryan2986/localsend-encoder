"""Local, cancelable FFmpeg encoding with verification before publishing a copy."""

import json
import math
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path

from send2trash import send2trash

VIDEO_SUFFIXES = {".mp4", ".m4v", ".mov"}
NO_CONSOLE = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


@dataclass(frozen=True)
class Preset:
    speed: str
    quality: int
    bounds: tuple
    suffix: str
    description: str


PRESETS = {
    "Fastest": Preset("ultrafast", 29, (960, 540), "-upload.mp4",
                      "Quick 540p-class H.264."),
    "Balanced": Preset("veryfast", 24, (1280, 720), "-balanced-upload.mp4",
                       "720p-class H.264 with more detail."),
    "Highest Quality": Preset("fast", 20, (), "-highest-quality-upload.mp4",
                              "Full-resolution H.264 with less compression."),
}


class EncodeError(Exception):
    pass


class Cancelled(Exception):
    pass


class Job:
    def __init__(self):
        self.lock = threading.Lock()
        self.cancelled = False
        self.finalizing = False
        self.process = None

    def cancel(self):
        with self.lock:
            if self.finalizing:
                return False
            self.cancelled = True
            if self.process is not None and self.process.poll() is None:
                try:
                    self.process.terminate()
                except ProcessLookupError:
                    pass
            return True

    def check(self):
        with self.lock:
            if self.cancelled:
                raise Cancelled()

    def commit(self):
        with self.lock:
            if self.cancelled:
                raise Cancelled()
            self.finalizing = True

    def run(self, argv, on_line):
        with tempfile.TemporaryFile() as error_log:
            with self.lock:
                if self.cancelled:
                    raise Cancelled()
                process = subprocess.Popen(
                    argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=error_log,
                    text=True, encoding="utf-8", errors="replace", creationflags=NO_CONSOLE,
                )
                self.process = process
            try:
                with process.stdout:
                    for line in process.stdout:
                        on_line(line.rstrip())
                result = process.wait()
            finally:
                with self.lock:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    self.process = None
            self.check()
            if result:
                error_log.seek(0, os.SEEK_END)
                error_log.seek(max(0, error_log.tell() - 3000))
                last_error = error_log.read().decode("utf-8", "replace").strip()
                raise EncodeError(last_error or f"{Path(argv[0]).name} exited with code {result}.")


def downloads_folder():
    if os.name == "nt":
        import winreg

        try:
            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
            ) as key:
                value, _ = winreg.QueryValueEx(key, "{374DE290-123F-4565-9164-39C4925E467B}")
                return Path(os.path.expandvars(value))
        except OSError:
            pass
    elif sys.platform.startswith("linux") and shutil.which("xdg-user-dir"):
        result = subprocess.run(["xdg-user-dir", "DOWNLOAD"], text=True, capture_output=True)
        if result.returncode == 0 and Path(result.stdout.strip()).is_absolute():
            return Path(result.stdout.strip())
    return Path.home() / "Downloads"


def identity(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not info.st_size:
        raise EncodeError("Choose a nonempty regular video file.")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def latest_video(folder):
    candidates = []
    if not folder.is_dir():
        return None
    for path in folder.iterdir():
        if path.name.startswith(".") or path.suffix.lower() not in VIDEO_SUFFIXES:
            continue
        try:
            candidates.append((identity(path)[3], path.name, path))
        except (EncodeError, OSError):
            continue
    return max(candidates)[2] if candidates else None


def executable(name):
    found = shutil.which(name)
    if found:
        return found
    if os.name == "nt" and "LOCALAPPDATA" in os.environ:
        winget_link = Path(os.environ["LOCALAPPDATA"]) / "Microsoft" / "WinGet" / "Links" / (name + ".exe")
        if winget_link.is_file():
            return str(winget_link)
    raise EncodeError(f"{name} wasn’t found. Install FFmpeg and make both tools available on PATH.")


def metadata(path, ffprobe, job):
    lines = []
    job.run([ffprobe, "-v", "error", "-protocol_whitelist", "file,pipe",
             "-show_streams", "-show_format", "-of", "json", str(path)], lines.append)
    data = json.loads("\n".join(lines))
    streams = data.get("streams", [])
    videos = [
        stream for stream in streams if stream.get("codec_type") == "video"
        and not stream.get("disposition", {}).get("attached_pic")
    ]
    audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
    try:
        duration = float(data["format"]["duration"])
    except (KeyError, TypeError, ValueError) as error:
        raise EncodeError("The video has no readable duration. Wait for the transfer to finish.") from error
    if not math.isfinite(duration) or duration <= 0 or len(videos) != 1:
        raise EncodeError("A readable video with one video track is required.")
    return duration, videos[0], len(audio)


def progress_reader(update, stage, duration):
    def read(line):
        key, _, raw = line.partition("=")
        if key == "out_time_us" and raw.lstrip("-").isdigit():
            percent = max(0, min(99, int(100 * int(raw) / 1_000_000 / duration)))
            update(stage, percent)
    return read


def encode(source, folder, preset, keep, job, update):
    source = source.absolute()
    original = identity(source)
    if source.suffix.lower() not in VIDEO_SUFFIXES:
        raise EncodeError("Choose an MP4, MOV, or M4V file.")
    ffmpeg, ffprobe = executable("ffmpeg"), executable("ffprobe")
    duration, video, audio_count = metadata(source, ffprobe, job)
    if video.get("color_transfer") in {"smpte2084", "arib-std-b67"}:
        raise EncodeError("HDR isn’t supported by these presets. The original was kept.")
    output = folder / (source.stem + preset.suffix)
    if output.exists() or output.is_symlink():
        raise EncodeError("This preset’s output already exists. Open Encoded Folder to find it.")
    folder.mkdir(parents=True, exist_ok=True)
    if preset.bounds:
        wide, tall = preset.bounds
        scale = (
            f"scale=w='min(iw,if(gte(iw,ih),{wide},{tall}))':"
            f"h='min(ih,if(gte(iw,ih),{tall},{wide}))':"
            "force_original_aspect_ratio=decrease:force_divisible_by=2"
        )
    else:
        scale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    base = [ffmpeg, "-hide_banner", "-nostdin", "-v", "error", "-xerror", "-nostats", "-progress", "pipe:1"]
    with tempfile.TemporaryDirectory(prefix=".video-encode-", dir=folder) as staging:
        copy = Path(staging) / "upload.mp4"
        update("Encoding", 0)
        job.run(base + [
            "-protocol_whitelist", "file,pipe", "-i", str(source),
            "-map", f"0:{video['index']}", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1",
            "-vf", scale, "-c:v", "libx264", "-preset", preset.speed, "-crf", str(preset.quality),
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
            "-n", str(copy),
        ], progress_reader(update, "Encoding", duration))
        verified = identity(copy)
        verified_size = verified[2]
        if verified_size >= original[2]:
            raise EncodeError("This preset didn’t make a smaller file. Try Fastest. The original was kept.")
        update("Verifying", 0)
        result_duration, _, result_audio = metadata(copy, ffprobe, job)
        if abs(result_duration - duration) > 1 or result_audio != audio_count:
            raise EncodeError("The copy has a duration or track mismatch. The original was kept.")
        job.run(base + [
            "-err_detect", "explode", "-protocol_whitelist", "file,pipe", "-i", str(copy),
            "-map", "0:v", "-map", "0:a?", "-fps_mode:v", "passthrough",
            "-enc_time_base:v", "1:1000000", "-f", "null", "-",
        ], progress_reader(update, "Verifying", duration))
        if identity(copy) != verified:
            raise EncodeError("The copy changed during verification. The original was kept.")
        if identity(source) != original:
            raise EncodeError("The source changed while encoding. The original was kept.")
        job.commit()
        update("Saving verified copy", 99)
        # Publish atomically without overwriting a file created by another instance.
        try:
            os.link(copy, output)
        except FileExistsError as error:
            raise EncodeError("The output already exists. The original was kept.") from error
        except OSError as error:
            raise EncodeError("The output folder must support hard links. The original was kept.") from error

    reduction = round(100 * (1 - verified_size / original[2]))
    result = f"{reduction}% smaller. Original kept."
    if not keep:
        try:
            if identity(source) != original:
                raise EncodeError("The original changed.")
            send2trash(str(source))
            result = f"{reduction}% smaller. Original moved to the Trash."
        except (OSError, EncodeError) as error:
            result = f"{reduction}% smaller. The verified copy was saved. Cleanup failed: {error}"
    return output, result
