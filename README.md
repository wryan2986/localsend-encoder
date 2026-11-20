# SpliceDesk

SpliceDesk is a desktop utility for compressing, joining, and muting MP4, MOV, and M4V videos on macOS, Windows, and Linux. All video processing happens on your computer. Formerly **LocalSend Encoder**, it works with videos from any source.

![SpliceDesk on macOS with a generated sample recording selected in the Compress workspace](docs/screenshot.png)

## Install

The commands below install the [v2.0.0 release](https://github.com/wryan2986/localsend-encoder/releases/tag/v2.0.0). Open **SpliceDesk** from Applications, Start, or your Linux app menu after installation.

### macOS

Requires macOS 14 or later. The source installer needs Xcode Command Line Tools (`xcode-select --install`) and FFmpeg. It installs FFmpeg through [Homebrew](https://brew.sh) if Homebrew is available. It also recognizes the standard Homebrew and MacPorts binary directories.

```bash
repo=wryan2986/localsend-encoder; tag=v2.0.0; curl -fsSL "https://raw.githubusercontent.com/$repo/$tag/scripts/bootstrap-unix.sh" | bash -s -- "https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
```

You can also download [SpliceDesk-macOS.zip](https://github.com/wryan2986/localsend-encoder/releases/download/v2.0.0/SpliceDesk-macOS.zip), extract it, and move **SpliceDesk.app** to Applications. The universal app includes Apple Silicon and Intel builds. The archive is ad hoc signed. The source installer builds and signs the app on your Mac if macOS blocks the downloaded build. For the archive installation, install [FFmpeg](https://ffmpeg.org/download.html) separately, for example with `brew install ffmpeg`.

### Windows

Requires Windows 10 or 11. In PowerShell, run the line below. WinGet supplies Python 3.12 and FFmpeg when either is missing. You can also extract the source archive and run **scripts/install-windows.cmd**.

```powershell
$repo='wryan2986/localsend-encoder'; $tag='v2.0.0'; & ([scriptblock]::Create((Invoke-RestMethod "https://raw.githubusercontent.com/$repo/$tag/scripts/bootstrap-windows.ps1"))) "https://github.com/$repo/archive/refs/tags/$tag.zip"
```

### Linux

Use a graphical desktop session. The installer can install dependencies through APT on Debian and Ubuntu. On other distributions, install Python 3.9 or later with Tk and venv, and FFmpeg 5.1 or later with `ffprobe` and `libx264` before running it. You can also run **scripts/install-linux.sh** from an extracted source archive.

```bash
repo=wryan2986/localsend-encoder; tag=v2.0.0; curl -fsSL "https://raw.githubusercontent.com/$repo/$tag/scripts/bootstrap-unix.sh" | bash -s -- "https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
```

## Use SpliceDesk

**Compress** opens with the latest video from Downloads. Choose **Fastest**, **Balanced**, or **Highest Quality**, then select **Export MP4**. The default output folder is `Downloads/Encoded`.

**Join Clips** prefills the newest video from `Downloads/Encoded` first and the newest download second. Choose either clip manually or use **Swap Order**. The output follows the first clip's shape and uses the primary audio track from each clip. The macOS app can copy compatible tracks directly. Clips that require conversion use H.264, and conversion expects SDR footage.

**Remove Audio** exports a silent MP4. It copies the video track directly for H.264, HEVC, AV1, and MPEG-4, and can convert other supported formats to H.264. Switch to this tool after exporting to start from the last result.

Use **Choose** to work with any supported file or **Use Latest Downloads** after a new transfer. Wait for the transfer to finish before exporting. Exports show progress, support cancellation, and pass a duration, track, and decode check before the app saves them. On Windows and Linux, choose an output folder that supports hard links, such as a local NTFS or ext4 volume.

| Quality | macOS | Windows and Linux |
| --- | --- | --- |
| Fastest | 540p-class H.264 | 540p-class H.264 |
| Balanced | 720p-class H.264 | 720p-class H.264 |
| Highest Quality | Source-resolution HEVC | Source-resolution H.264 with less compression |

**Keep original file** is on by default. Compression can move the source to the operating system's Trash or Recycle Bin after a smaller copy passes verification. Join Clips and Remove Audio always save a separate copy.

## Build and test

- **macOS:** Run `./scripts/build-macos.sh`. Set `ENCODER_MAC_ARCH=universal` to build for Apple Silicon and Intel. At runtime, the app uses FFmpeg plus Apple's `avconvert` for compression.
- **Windows and Linux:** With Python, Tk, and FFmpeg installed, create a virtual environment, run `python -m pip install -r requirements.txt`, then run `python portable/app.py`.
- **Verification:** Run `python -m unittest discover -s tests -v` and `python tests/smoke_window.py` in a graphical session. The tests use generated clips. For automated checks, see [Desktop checks](https://github.com/wryan2986/localsend-encoder/actions/workflows/ci.yml), [one-line installers](https://github.com/wryan2986/localsend-encoder/actions/workflows/release-installers.yml), and [clean Windows with WinGet](https://github.com/wryan2986/localsend-encoder/actions/workflows/windows-clean-install.yml).

## Uninstall

- **macOS:** Quit SpliceDesk and move it from Applications to the Trash.
- **Windows:** Remove the SpliceDesk Start menu shortcut and the `LocalSend Encoder` folder in `%LOCALAPPDATA%\Programs`. The installer retains that directory name for upgrades.
- **Linux:** Remove `localsend-encoder` and `applications/localsend-encoder.desktop` under `${XDG_DATA_HOME:-$HOME/.local/share}`.

## License

[MIT](LICENSE)
