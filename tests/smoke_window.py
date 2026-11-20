"""Check that the desktop window opens predictably without starting a job."""
import os
import sys
import tempfile
import tkinter as tk
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "portable"))
from app import EncoderApp

with tempfile.TemporaryDirectory() as tmp:
    fixture = Path(tmp) / "test-recording.mp4"
    fixture.write_bytes(b"Only used to test file selection")
    root = tk.Tk()
    with patch("app.downloads_folder", return_value=Path(tmp)):
        app = EncoderApp(root)
    root.update()
    assert app.keep.get() and app.preset.get() == "Fastest"
    assert app.path == fixture and app.job is None
    with patch("app.filedialog.askopenfilename", return_value=str(fixture)):
        app.choose()
    assert app.manual_selection and app.path == fixture
    newest = Path(tmp) / "new-transfer.mp4"
    newest.write_bytes(b"Used for refresh selection only")
    stamp = fixture.stat().st_mtime + 2
    os.utime(newest, (stamp, stamp))
    app.refresh_button.invoke()
    assert app.path == newest and not app.manual_selection and app.job is None
    assert app.keep.get() and app.preset.get() == "Fastest"
    app.folder.mkdir()
    first_clip = app.folder / "encoded-first.mp4"
    first_clip.write_bytes(b"Used to check the Join Clips layout")
    app.tool_buttons["Join Clips"].invoke()
    root.update()
    assert app.second_card.winfo_ismapped() and not app.options.winfo_ismapped()
    assert app.path == first_clip and app.second_path == newest
    app.swap_button.invoke()
    assert app.path == newest and app.second_path == first_clip
    app.tool_buttons["Remove Audio"].invoke()
    root.update()
    assert not app.second_card.winfo_ismapped() and not app.options.winfo_ismapped()
    assert app.path == newest and app.job is None
    app.tool_buttons["Compress"].invoke()
    root.update()
    assert app.options.winfo_ismapped() and app.keep.get() and app.job is None
    root.destroy()
