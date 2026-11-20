"""SpliceDesk desktop window for Windows and Linux."""

import os
import queue
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, ttk

from edits import export_edit
from encoder import Cancelled, Job, PRESETS, downloads_folder, encode, latest_video


TOOLS = {
    "Compress": "Export a smaller MP4 for uploading or sharing.",
    "Join Clips": "Place two clips back to back in a single MP4.",
    "Remove Audio": "Export an MP4 with the audio track removed.",
}
FORMATS = [("Video files", "*.mp4 *.mov *.m4v"), ("All files", "*")]


class EncoderApp:
    def __init__(self, root):
        self.root = root
        self.downloads = downloads_folder()
        self.folder = self.downloads / "Encoded"
        self.tool = "Compress"
        self.path = None
        self.second_path = None
        self.last_result = None
        self.manual_selection = False
        self.job = None
        self.events = queue.Queue()
        self.close_when_done = False
        self.filename = tk.StringVar(value="Choose a video")
        self.second_name = tk.StringVar(value="Choose a second clip")
        self.preset = tk.StringVar(value="Fastest")
        self.preset_detail = tk.StringVar(value=PRESETS["Fastest"].description)
        self.keep = tk.BooleanVar(value=True)
        self.status = tk.StringVar(value="Ready")
        self.detail = tk.StringVar()
        self.progress = tk.IntVar(value=0)

        root.title("SpliceDesk")
        root.minsize(760, 440)
        root.columnconfigure(1, weight=1)
        root.rowconfigure(0, weight=1)
        root.protocol("WM_DELETE_WINDOW", self.close)
        self.styles()
        self.build_sidebar(root)
        self.build_workspace(root)
        self.apply_tool()
        self.select_latest()
        root.bind("<FocusIn>", self.refresh_on_focus, add=True)
        root.after(80, self.poll)

    def styles(self):
        style = ttk.Style(self.root)
        if "clam" in style.theme_names():
            style.theme_use("clam")
        ink, muted, paper, rail = "#19223a", "#505d75", "#f6f7fb", "#e8eaf4"
        style.configure("TFrame", background=paper)
        style.configure("TLabel", background=paper, foreground=ink)
        style.configure("TCheckbutton", background=paper, foreground=ink)
        style.map("TCheckbutton", background=[("active", paper)])
        style.configure("Rail.TFrame", background=rail)
        style.configure("Rail.TLabel", background=rail, foreground=ink, font=("TkDefaultFont", 15, "bold"))
        style.configure("Heading.TLabel", font=("TkDefaultFont", 23, "bold"))
        style.configure("Detail.TLabel", foreground=muted)
        style.configure("Card.TFrame", background="white")
        style.configure("Card.TLabel", background="white", foreground=ink)
        style.configure("CardTitle.TLabel", background="white", foreground=muted)
        style.configure("TButton", padding=(10, 6))
        style.configure("Tool.TButton", anchor="w", padding=(11, 8), background=rail, foreground=ink)
        style.configure("Selected.Tool.TButton", background="#d9d8f7", foreground="#322772")
        style.map("Selected.Tool.TButton", background=[("active", "#cecbf4")])
        style.configure("Primary.TButton", foreground="white", background="#5542b4", padding=(12, 7))
        style.map("Primary.TButton", background=[("disabled", "#e2e3ed"), ("active", "#4937a3")],
                  foreground=[("disabled", "#5e657b")])
        style.configure("Horizontal.TProgressbar", background="#6554ca", troughcolor="#e4e5ee")

    def build_sidebar(self, root):
        rail = ttk.Frame(root, style="Rail.TFrame", width=182, padding=(14, 19))
        rail.grid(row=0, column=0, sticky="ns")
        rail.grid_propagate(False)
        rail.columnconfigure(0, weight=1)
        icon_path = Path(__file__).resolve().parent.parent / "assets" / "AppIcon.png"
        self.icon = None
        if icon_path.is_file():
            try:
                self.icon = tk.PhotoImage(file=str(icon_path)).subsample(8, 8)
                root.iconphoto(True, self.icon)
            except tk.TclError:
                pass  # Older Tk builds do not provide PNG icons.
        ttk.Label(rail, text="SpliceDesk", image=self.icon or "", compound="left",
                  style="Rail.TLabel").grid(sticky="w", pady=(0, 19))
        self.tool_buttons = {}
        for tool in TOOLS:
            button = ttk.Button(rail, text=tool, style="Tool.TButton", command=lambda value=tool: self.change_tool(value))
            button.grid(sticky="ew", pady=(0, 6))
            self.tool_buttons[tool] = button

    def build_workspace(self, root):
        main = ttk.Frame(root, padding=(24, 21))
        main.grid(row=0, column=1, sticky="nsew")
        main.columnconfigure(0, weight=1)
        self.heading = ttk.Label(main, style="Heading.TLabel")
        self.heading.grid(sticky="w")
        self.intro = ttk.Label(main, style="Detail.TLabel")
        self.intro.grid(sticky="w", pady=(2, 14))

        first, self.first_title, self.choose_button = self.source_card(main, self.filename, self.choose)
        first.grid(sticky="ew")
        self.second_card, second_title, self.second_button = self.source_card(
            main, self.second_name, lambda: self.choose(second=True),
        )
        second_title.configure(text="2. Next clip")
        self.second_card.grid(sticky="ew", pady=(8, 0))
        self.swap_button = ttk.Button(main, text="Swap Order", command=self.swap)
        self.swap_button.grid(sticky="w", pady=(6, 0))

        self.options = ttk.Frame(main)
        self.options.grid(sticky="ew", pady=(10, 0))
        ttk.Label(self.options, text="Quality").grid(row=0, column=0, sticky="w", padx=(0, 8))
        self.preset_picker = ttk.Combobox(
            self.options, textvariable=self.preset, values=tuple(PRESETS), state="readonly", width=18,
        )
        self.preset_picker.grid(row=0, column=1, sticky="w")
        self.preset_picker.bind(
            "<<ComboboxSelected>>", lambda _event: self.preset_detail.set(PRESETS[self.preset.get()].description),
        )
        ttk.Label(self.options, textvariable=self.preset_detail, style="Detail.TLabel").grid(
            row=1, columnspan=2, sticky="w", pady=(4, 2),
        )
        self.keep_button = ttk.Checkbutton(
            self.options, text="Keep original file", variable=self.keep, command=self.describe_cleanup,
        )
        self.keep_button.grid(row=2, columnspan=2, sticky="w")

        ttk.Separator(main).grid(sticky="ew", pady=(13, 9))
        ttk.Label(main, textvariable=self.status, font=("TkDefaultFont", 11, "bold")).grid(sticky="w")
        status_detail = ttk.Label(main, textvariable=self.detail, style="Detail.TLabel", wraplength=490)
        status_detail.grid(sticky="ew", pady=(2, 7))
        ttk.Progressbar(main, maximum=100, variable=self.progress).grid(sticky="ew")
        actions = ttk.Frame(main)
        actions.grid(sticky="ew", pady=(11, 0))
        self.refresh_button = ttk.Button(actions, text="Use Latest Downloads", command=self.refresh)
        self.refresh_button.pack(side="left")
        self.folder_button = ttk.Button(actions, text="Open Output Folder", command=self.open_folder)
        self.folder_button.pack(side="left", padx=6)
        self.encode_button = ttk.Button(actions, text="Export MP4…", command=self.start, style="Primary.TButton")
        self.encode_button.pack(side="right")
        self.cancel_button = ttk.Button(actions, text="Cancel", command=self.cancel)

    @staticmethod
    def source_card(parent, value, choose):
        card = ttk.Frame(parent, style="Card.TFrame", padding=(12, 8))
        card.columnconfigure(0, weight=1)
        title = ttk.Label(card, style="CardTitle.TLabel")
        title.grid(row=0, column=0, sticky="w")
        name = ttk.Label(card, textvariable=value, style="Card.TLabel", width=40, anchor="w")
        name.grid(row=1, column=0, sticky="ew", pady=(2, 0))
        button = ttk.Button(card, text="Choose…", command=choose)
        button.grid(row=0, column=1, rowspan=2, sticky="e", padx=(8, 0))
        return card, title, button

    def apply_tool(self):
        self.heading.configure(text=self.tool)
        self.intro.configure(text=TOOLS[self.tool])
        joining = self.tool == "Join Clips"
        self.first_title.configure(text="1. First clip" if joining else "Source video")
        for widget in (self.second_card, self.swap_button):
            widget.grid() if joining else widget.grid_remove()
        self.options.grid() if self.tool == "Compress" else self.options.grid_remove()
        self.encode_button.configure(text="Export MP4" if self.tool == "Compress" else "Export MP4…")
        for tool, button in self.tool_buttons.items():
            button.configure(style="Selected.Tool.TButton" if self.tool == tool else "Tool.TButton")

    def change_tool(self, tool):
        if self.job or tool == self.tool:
            return
        self.tool = tool
        self.manual_selection = False
        self.apply_tool()
        if tool == "Remove Audio" and self.last_result and self.last_result.is_file():
            self.manual_selection = True
            self.select(self.last_result)
        else:
            self.select_latest()

    def select_latest(self):
        try:
            latest = latest_video(self.downloads)
            if self.tool == "Join Clips":
                self.select(latest_video(self.folder, encoded=True), latest)
            else:
                self.select(latest)
        except OSError:
            self.select(None)
            self.detail.set("Downloads couldn’t be read. Use Choose to select a file.")

    def refresh(self):
        if self.job is None:
            self.manual_selection = False
            self.select_latest()

    def refresh_on_focus(self, event):
        if (event.widget == self.root and self.job is None and not self.manual_selection
                and self.last_result is None and self.tool == "Compress"):
            try:
                latest = latest_video(self.downloads)
            except OSError:
                return
            if latest != self.path:
                self.select(latest)

    def describe_cleanup(self):
        if self.ready() and self.job is None:
            if self.tool == "Compress":
                self.detail.set("Exports to Downloads/Encoded." if self.keep.get()
                                else "The original moves to the Trash after verification.")
            elif self.tool == "Join Clips":
                self.detail.set("Clips play in the order shown.")
            else:
                self.detail.set("Choose where to save the silent copy.")

    def ready(self):
        return self.path is not None and (self.tool != "Join Clips" or self.second_path is not None)

    def select(self, path, second=None):
        self.path, self.second_path = path, second
        self.filename.set(path.name if path else "Choose a video")
        self.second_name.set(second.name if second else "Choose a second clip")
        self.status.set("Ready to export" if self.ready() else "Select your source")
        self.detail.set("Choose an MP4, MOV, or M4V file.")
        self.describe_cleanup()
        self.progress.set(0)
        self.controls()

    def choose(self, second=False):
        current = self.second_path if second else self.path
        initial = current.parent if current else self.downloads
        path = filedialog.askopenfilename(
            title="Choose a video", initialdir=initial if initial.is_dir() else Path.home(), filetypes=FORMATS,
        )
        if path:
            self.manual_selection = True
            if second:
                self.select(self.path, Path(path))
            else:
                self.select(Path(path), self.second_path)

    def swap(self):
        self.manual_selection = True
        self.select(self.second_path, self.path)

    def controls(self):
        idle = self.job is None
        state = "normal" if idle else "disabled"
        for button in (self.choose_button, self.second_button, self.refresh_button, self.keep_button,
                       *self.tool_buttons.values()):
            button.configure(state=state)
        self.preset_picker.configure(state="readonly" if idle else "disabled")
        self.swap_button.configure(state="normal" if idle and self.ready() else "disabled")
        self.encode_button.configure(state="normal" if idle and self.ready() else "disabled")
        if idle:
            self.cancel_button.pack_forget()
            if self.last_result or self.folder.is_dir():
                self.folder_button.pack(side="left", padx=6)
            else:
                self.folder_button.pack_forget()
        else:
            self.folder_button.pack_forget()
            self.cancel_button.configure(state="normal")
            self.cancel_button.pack(side="right", padx=7)

    def start(self):
        if self.job or not self.ready():
            return
        destination = None
        if self.tool != "Compress":
            suffix = "-joined" if self.tool == "Join Clips" else "-silent"
            name = self.path.stem + suffix
            suggested = name + ".mp4"
            index = 2
            while (self.downloads / suggested).exists():
                suggested = f"{self.path.stem}-{index}{suffix}.mp4"
                index += 1
            chosen = filedialog.asksaveasfilename(
                title="Export MP4", initialdir=self.downloads, initialfile=suggested,
                defaultextension=".mp4", filetypes=[("MP4 video", "*.mp4")],
            )
            if not chosen:
                return
            destination = Path(chosen)
        self.job = Job()
        keep = self.keep.get()
        self.keep.set(True)
        self.controls()
        self.status.set("Preparing export…")
        self.detail.set(self.path.name)
        self.progress.set(0)
        threading.Thread(target=self.worker, daemon=True,
                         args=(self.path, self.second_path, destination, PRESETS[self.preset.get()],
                               keep, self.job)).start()

    def worker(self, path, second, destination, preset, keep, job):
        def update(stage, percent):
            self.events.put(("progress", stage, percent))
        try:
            if destination is None:
                destination, message = encode(path, self.folder, preset, keep, job, update)
            else:
                sources = [path, second] if second is not None else [path]
                export_edit(sources, destination, job, update)
                message = destination.name
            self.events.put(("done", "Export complete", (message, destination)))
        except Cancelled:
            self.events.put(("done", "Export canceled", ("The source files were kept.", None)))
        except Exception as error:
            self.events.put(("done", "Export failed", (str(error) or type(error).__name__, None)))

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
                    message, result = detail
                    if result is not None:
                        self.last_result = result
                    self.status.set(value)
                    self.detail.set(message)
                    self.progress.set(100 if result else 0)
                    if self.path and not self.path.exists():
                        self.path = None
                        self.manual_selection = False
                        self.filename.set("Choose a video")
                    self.controls()
                    if self.close_when_done:
                        self.root.destroy()
                        return
        except queue.Empty:
            self.root.after(80, self.poll)

    def open_folder(self):
        folder = self.last_result.parent if self.last_result else self.folder
        try:
            if os.name == "nt":
                os.startfile(str(folder))
            else:
                subprocess.Popen(["xdg-open", str(folder)])
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
