"""LocalSend Encoder desktop window for Windows and Linux."""

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk

from encoder import Cancelled, EncodeError, Job, PRESETS, downloads_folder, encode, latest_video


class EncoderApp:
    def __init__(self, root):
        self.root = root
        self.downloads = downloads_folder()
        self.folder = self.downloads / "Encoded"
        self.path = None
        self.manual_selection = False
        self.job = None
        self.events = queue.Queue()
        self.close_when_done = False
        self.filename = tk.StringVar(value="No video selected")
        self.preset = tk.StringVar(value="Fastest")
        self.preset_detail = tk.StringVar(value=PRESETS["Fastest"].description)
        self.keep = tk.BooleanVar(value=True)
        self.status = tk.StringVar(value="Ready")
        self.detail = tk.StringVar(value="Click Encode to start.")
        self.progress = tk.IntVar(value=0)

        root.title("LocalSend Encoder")
        root.minsize(480, 340)
        root.columnconfigure(0, weight=1)
        root.rowconfigure(0, weight=1)
        root.protocol("WM_DELETE_WINDOW", self.close)
        icon_path = Path(__file__).resolve().parent.parent / "assets" / "AppIcon.png"
        if icon_path.is_file():
            self.icon = tk.PhotoImage(file=str(icon_path)).subsample(16, 16)
            root.iconphoto(True, self.icon)
        main = ttk.Frame(root, padding=20)
        main.grid(sticky="nsew")
        main.columnconfigure(0, weight=1)
        ttk.Label(main, text="Source video").grid(row=0, sticky="w")
        ttk.Label(main, textvariable=self.filename, wraplength=335).grid(row=1, sticky="w", pady=(3, 12))
        file_actions = ttk.Frame(main)
        file_actions.grid(row=1, column=1, sticky="e")
        self.refresh_button = ttk.Button(file_actions, text="Refresh", command=self.refresh)
        self.refresh_button.pack(side="left", padx=(0, 6))
        self.choose_button = ttk.Button(file_actions, text="Choose File…", command=self.choose)
        self.choose_button.pack(side="left")
        options = ttk.Frame(main)
        options.grid(row=2, columnspan=2, sticky="w")
        ttk.Label(options, text="Encoding preset").pack(side="left", padx=(0, 8))
        self.preset_picker = ttk.Combobox(
            options, textvariable=self.preset, values=tuple(PRESETS), state="readonly", width=17,
        )
        self.preset_picker.pack(side="left")
        self.preset_picker.bind(
            "<<ComboboxSelected>>", lambda _event: self.preset_detail.set(PRESETS[self.preset.get()].description),
        )
        ttk.Label(main, textvariable=self.preset_detail).grid(row=3, columnspan=2, sticky="w", pady=(4, 6))
        self.keep_button = ttk.Checkbutton(main, text="Keep Original", variable=self.keep, command=self.describe_cleanup)
        self.keep_button.grid(row=4, columnspan=2, sticky="w", pady=(0, 17))
        ttk.Label(main, textvariable=self.status, font=("TkDefaultFont", 13, "bold")).grid(row=5, sticky="w")
        ttk.Label(main, textvariable=self.detail, wraplength=430).grid(row=6, columnspan=2, sticky="w", pady=(3, 8))
        ttk.Progressbar(main, maximum=100, variable=self.progress).grid(row=7, columnspan=2, sticky="ew")
        actions = ttk.Frame(main)
        actions.grid(row=8, columnspan=2, sticky="ew", pady=(12, 0))
        self.folder_button = ttk.Button(actions, text="Open Encoded Folder", command=self.open_folder)
        self.folder_button.pack(side="left")
        self.encode_button = ttk.Button(actions, text="Encode", command=self.start)
        self.encode_button.pack(side="right")
        self.cancel_button = ttk.Button(actions, text="Cancel", command=self.cancel)
        self.cancel_button.pack(side="right", padx=8)
        self.select_latest()
        root.bind("<FocusIn>", self.refresh_on_focus, add=True)
        root.after(80, self.poll)

    def select_latest(self):
        try:
            self.select(latest_video(self.downloads))
        except OSError:
            self.select(None)
            self.detail.set("Downloads couldn’t be read. Try Choose File.")

    def refresh(self):
        if self.job is None:
            self.manual_selection = False
            self.select_latest()

    def refresh_on_focus(self, event):
        if event.widget == self.root and self.job is None and not self.manual_selection:
            try:
                candidate = latest_video(self.downloads)
                if candidate != self.path:
                    self.select(candidate)
            except OSError:
                pass

    def describe_cleanup(self):
        if self.path and self.job is None:
            self.detail.set("The original will stay in place." if self.keep.get()
                            else "After verification, the original moves to the Trash.")

    def select(self, path):
        self.path = path
        self.filename.set(path.name if path else "No video selected")
        self.status.set("Ready" if path else "Choose a video")
        self.detail.set("Supported files are MP4, MOV, and M4V.")
        self.describe_cleanup()
        self.progress.set(0)
        self.controls()

    def choose(self):
        initial = self.path.parent if self.path else self.downloads
        path = filedialog.askopenfilename(
            title="Choose a video to encode", initialdir=initial if initial.is_dir() else Path.home(),
            filetypes=[("Video files", "*.mp4 *.mov *.m4v"), ("All files", "*")],
        )
        if path:
            self.manual_selection = True
            self.select(Path(path))

    def controls(self):
        idle = self.job is None
        self.choose_button.configure(state="normal" if idle else "disabled")
        self.refresh_button.configure(state="normal" if idle else "disabled")
        self.keep_button.configure(state="normal" if idle else "disabled")
        self.preset_picker.configure(state="readonly" if idle else "disabled")
        self.encode_button.configure(state="normal" if idle and self.path else "disabled")
        self.cancel_button.configure(state="disabled" if idle else "normal")
        self.folder_button.configure(state="normal" if self.folder.is_dir() else "disabled")

    def start(self):
        if self.job or self.path is None:
            return
        self.job = Job()
        self.controls()
        self.status.set("Preparing…")
        self.detail.set(self.path.name)
        self.progress.set(0)
        threading.Thread(target=self.worker, daemon=True,
                         args=(self.path, PRESETS[self.preset.get()], self.keep.get(), self.job)).start()

    def worker(self, path, preset, keep, job):
        try:
            _, message = encode(path, self.folder, preset, keep, job,
                                lambda stage, percent: self.events.put(("progress", stage, percent)))
            self.events.put(("done", "Ready to upload", message))
        except Cancelled:
            self.events.put(("done", "Canceled", "The original was kept."))
        except Exception as error:
            self.events.put(("done", "Couldn’t finish", str(error) or type(error).__name__))

    def cancel(self):
        if self.job and self.job.cancel():
            self.status.set("Canceling…")
            self.cancel_button.configure(state="disabled")

    def poll(self):
        try:
            while True:
                kind, value, detail = self.events.get_nowait()
                if kind == "progress" and self.status.get() != "Canceling…":
                    self.progress.set(detail)
                    self.status.set(f"{value}… {detail}%")
                    if value == "Saving verified copy":
                        self.cancel_button.configure(state="disabled")
                elif kind == "done":
                    self.job = None
                    self.status.set(value)
                    self.detail.set(detail)
                    self.progress.set(100 if value == "Ready to upload" else 0)
                    if self.path and not self.path.exists():
                        self.path = None
                        self.manual_selection = False
                        self.filename.set("No video selected")
                    self.controls()
                    if self.close_when_done:
                        self.root.destroy()
                        return
        except queue.Empty:
            self.root.after(80, self.poll)

    def open_folder(self):
        try:
            if os.name == "nt":
                os.startfile(str(self.folder))
            else:
                command = "open" if sys.platform == "darwin" else "xdg-open"
                subprocess.Popen([command, str(self.folder)])
        except OSError as error:
            self.detail.set(str(error))

    def close(self):
        if self.job is None:
            self.root.destroy()
        else:
            self.close_when_done = True
            self.cancel()


if __name__ == "__main__":
    try:
        window = tk.Tk()
        EncoderApp(window)
        window.mainloop()
    except tk.TclError as error:
        raise SystemExit(f"A desktop session with Tk is required: {error}") from error
