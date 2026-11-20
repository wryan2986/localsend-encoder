"""Check that the desktop window opens predictably without starting a job."""
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
    root.destroy()
