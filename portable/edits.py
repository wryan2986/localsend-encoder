"""Join two clips or export a video without audio."""

import math
import os
import tempfile
from pathlib import Path

from encoder import (EncodeError, executable, ffmpeg_command, identity, metadata,
                     progress_reader, publish, verify_export)


COPY_CODECS = {"h264", "hevc", "av1", "mpeg4"}
HDR_TRANSFERS = {"smpte2084", "arib-std-b67"}
LOCAL_INPUT = ["-protocol_whitelist", "file,pipe", "-i"]


def video_duration(media):
    duration, track, _ = media
    try:
        video_seconds = float(track.get("duration", duration))
    except (TypeError, ValueError):
        return duration
    return video_seconds if math.isfinite(video_seconds) and video_seconds > 0 else duration


def display_size(track):
    width, height = track["width"], track["height"]
    try:
        numerator, denominator = map(int, track["sample_aspect_ratio"].split(":"))
        if numerator > 0 and denominator > 0:
            width = round(width * numerator / denominator)
    except (AttributeError, KeyError, ValueError):
        pass
    rotation = next((item["rotation"] for item in track.get("side_data_list", []) if "rotation" in item), 0)
    if abs(rotation) % 180 == 90:
        width, height = height, width
    return max(2, min(width // 2 * 2, 8192)), max(2, min(height // 2 * 2, 8192))


def export_edit(sources, destination, job, update):
    sources = [path.absolute() for path in sources]
    if len(sources) not in (1, 2):
        raise EncodeError("Choose one source for Remove Audio or two clips for Join Clips.")
    originals = [identity(path) for path in sources]
    if len(sources) == 2 and os.path.samefile(*sources):
        raise EncodeError("Choose two different clips.")
    if destination.exists() or destination.is_symlink():
        raise EncodeError("A file already exists at this destination. Choose a new name.")
    base, ffprobe = ffmpeg_command(), executable("ffprobe")
    input_args = [arg for path in sources for arg in LOCAL_INPUT + [str(path)]]
    media = [metadata(path, ffprobe, job) for path in sources]
    duration = sum(map(video_duration, media))

    if len(sources) == 1:
        track = media[0][1]
        codec = track.get("codec_name")
        copy_video = codec in COPY_CODECS
        args = ["-map", f"0:{track['index']}"]
        if copy_video:
            args += ["-c:v", "copy"]
            if codec == "hevc":
                args += ["-tag:v", "hvc1"]
        else:
            if track.get("color_transfer") in HDR_TRANSFERS:
                raise EncodeError("This HDR format requires conversion to SDR before export.")
            args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                     "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p", "-fps_mode:v", "passthrough"]
        audio_count = 0
        phase = "Removing audio" if copy_video else "Converting to a silent MP4"
    else:
        audio_count = int(any(item[2] for item in media))
        args = join_args(media, audio_count)
        phase = "Joining clips"
        copy_video = False

    with tempfile.TemporaryDirectory(prefix=".splicedesk-", dir=destination.parent) as staging:
        output = Path(staging) / "export.mp4"
        update(phase, 0)
        job.run(base + input_args + args + ["-movflags", "+faststart", "-n", str(output)],
                progress_reader(update, phase, duration))
        verified = verify_export(output, duration, audio_count, base, ffprobe, job, update)
        if copy_video and track.get("nb_frames") and verified.get("nb_frames"):
            if verified["nb_frames"] != track["nb_frames"]:
                raise EncodeError("The silent copy has a frame count mismatch.")
        if [identity(path) for path in sources] != originals:
            raise EncodeError("A source changed during export. Try again after the transfer finishes.")
        publish(output, destination, job, update)


def join_args(clips, audio_count):
    if any(track.get("color_transfer") in HDR_TRANSFERS for _, track, _ in clips):
        raise EncodeError("Convert HDR clips to SDR before joining them on this platform.")
    canvas_width, canvas_height = display_size(clips[0][1])
    filters, segments = [], []
    for index, media in enumerate(clips):
        _, track, tracks_with_audio = media
        width, height = display_size(track)
        scale = min(canvas_width / width, canvas_height / height)
        width = max(2, int(width * scale / 2) * 2)
        height = max(2, int(height * scale / 2) * 2)
        filters.append(
            f"[{index}:{track['index']}]scale={width}:{height},setsar=1,"
            f"pad={canvas_width}:{canvas_height}:(ow-iw)/2:(oh-ih)/2,format=yuv420p,"
            f"settb=AVTB,setpts=PTS-STARTPTS[v{index}]"
        )
        segments.append(f"[v{index}]")
        if audio_count:
            audio = (f"[{index}:a:0]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,apad"
                     if tracks_with_audio else "anullsrc=r=48000:cl=stereo")
            filters.append(f"{audio},atrim=duration={video_duration(media)},asetpts=PTS-STARTPTS[a{index}]")
            segments.append(f"[a{index}]")
    filters.append("".join(segments) + f"concat=n=2:v=1:a={audio_count}[v]" + ("[a]" if audio_count else ""))
    args = [
        "-filter_complex", ";".join(filters), "-map", "[v]", "-fps_mode:v", "passthrough",
        "-enc_time_base:v", "1:1000000", "-c:v", "libx264", "-preset", "veryfast", "-crf", "21",
    ]
    if audio_count:
        args += ["-map", "[a]", "-c:a", "aac", "-b:a", "128k"]
    return args
