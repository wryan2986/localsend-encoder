"""Install the Python desktop app and a per-user launcher."""

import importlib.util
import os
import shlex
import shutil
import subprocess
import sys
import venv
from pathlib import Path


def desktop_escape(value):
    return value.replace("\\", "\\\\").replace("\n", "\\n")


def desktop_exec(path):
    # Exec has its own quoting layer, applied after Desktop Entry escaping.
    text = str(path).replace("%", "%%")
    for character in ('\\', '"', '`', '$'):
        text = text.replace(character, "\\" + character)
    return desktop_escape('"' + text + '"')


def install():
    if sys.version_info < (3, 9) or importlib.util.find_spec("tkinter") is None:
        raise SystemExit("Python 3.9 or later with Tk is required.")
    source = Path(__file__).resolve().parent.parent
    windows = os.name == "nt"
    if windows:
        target = Path(os.environ["LOCALAPPDATA"]) / "Programs" / "LocalSend Encoder"
    elif sys.platform.startswith("linux"):
        target = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "localsend-encoder"
    else:
        raise SystemExit("Use install-macos.sh for the native Mac app.")
    target.mkdir(parents=True, exist_ok=True)

    environment = target / "venv"
    venv.EnvBuilder(with_pip=True).create(environment)
    executable = environment / ("Scripts/python.exe" if windows else "bin/python")
    subprocess.run([str(executable), "-m", "pip", "install", "--disable-pip-version-check",
                    "-r", str(source / "requirements.txt")], check=True)
    for name in ("portable", "assets"):
        shutil.copytree(source / name, target / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__", "*.icns"))
    app = target / "portable" / "app.py"

    if windows:
        # WScript.Shell resolves the user's real Start Menu folder and creates a shortcut.
        shortcut_script = (
            "$ErrorActionPreference = 'Stop'; "
            "$shell = New-Object -ComObject WScript.Shell; "
            "$programs = [Environment]::GetFolderPath('Programs'); "
            "$link = $shell.CreateShortcut((Join-Path $programs 'LocalSend Encoder.lnk')); "
            "$link.TargetPath = $env:ENCODER_PYTHON; "
            "$link.Arguments = [string][char]34 + $env:ENCODER_APP + [char]34; "
            "$link.WorkingDirectory = $env:ENCODER_ROOT; "
            "$link.IconLocation = $env:ENCODER_ICON; $link.Save()"
        )
        subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", shortcut_script], check=True,
                       env=dict(os.environ, ENCODER_PYTHON=str(executable.with_name("pythonw.exe")),
                                ENCODER_APP=str(app), ENCODER_ROOT=str(target),
                                ENCODER_ICON=str(target / "assets" / "AppIcon.ico")))
    else:
        launcher = target / "launch"
        launcher.write_text(f"#!/bin/sh\nexec {shlex.quote(str(executable))} {shlex.quote(str(app))}\n",
                            encoding="utf-8")
        launcher.chmod(0o755)
        applications = target.parent / "applications"
        applications.mkdir(parents=True, exist_ok=True)
        icon = desktop_escape(str(target / "assets" / "AppIcon.png"))
        (applications / "localsend-encoder.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=LocalSend Encoder\n"
            "Comment=Make a smaller MP4 from your latest video\n"
            f"Exec={desktop_exec(launcher)}\nIcon={icon}\nTerminal=false\nCategories=AudioVideo;Video;\n",
            encoding="utf-8",
        )
    print("Installed. Open LocalSend Encoder from your app menu.")


if __name__ == "__main__":
    install()
