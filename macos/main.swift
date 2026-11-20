import AppKit
import UniformTypeIdentifiers

private enum VideoTool: String, CaseIterable {
    case encode = "Compress"
    case join = "Join Clips"
    case mute = "Remove Audio"

    var detail: String {
        switch self {
        case .encode: return "Export a smaller MP4 for uploading or sharing."
        case .join: return "Place two clips back to back in a single MP4."
        case .mute: return "Export an MP4 with the audio track removed."
        }
    }

    var symbol: String {
        switch self {
        case .encode: return "arrow.down.right.and.arrow.up.left"
        case .join: return "link"
        case .mute: return "speaker.slash"
        }
    }
}

final class VideoJoiner: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = JoinEngine(tools: Bundle.main.resourceURL!)
    private let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private let queue = DispatchQueue(label: "local.splicedesk.worker", qos: .userInitiated)

    private var window: NSWindow!
    private var selected: [URL?] = [nil, nil]
    private var activeJob: JoinJob?
    private var lastResult: URL?
    private var refreshing = false
    private var tool = VideoTool.encode
    private var toolButtons: [NSButton] = []
    private let heading = NSTextField(labelWithString: "")
    private let presetPicker = NSPopUpButton()
    private let firstTitle = NSTextField(labelWithString: "Source video")
    private let subtitle = NSTextField(wrappingLabelWithString: "")
    private let presetHelp = NSTextField(wrappingLabelWithString: "")
    private lazy var keepOriginal = NSButton(checkboxWithTitle: "Keep Original", target: nil, action: nil)
    private var secondRow: NSView!
    private var encodeOptions: NSView!

    private let filenames = ["Choose the first video", "Choose a video to append"].map {
        NSTextField(labelWithString: $0)
    }
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private lazy var firstButton = button("Choose…", #selector(chooseFirst))
    private lazy var secondButton = button("Choose…", #selector(chooseSecond))
    private lazy var refreshButton = button("Use Latest Downloads", #selector(refresh))
    private lazy var joinButton = button("Export MP4…", #selector(save))
    private lazy var cancelButton = button("Cancel", #selector(cancel))
    private lazy var revealButton = button("Show in Finder", #selector(reveal))
    private lazy var swapButton = button("Swap Order", #selector(swapOrder))

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 770, height: 425),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "SpliceDesk"
        window.delegate = self

        heading.font = .systemFont(ofSize: 30, weight: .bold)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)
        let intro = stack([heading, subtitle], spacing: 5)

        let first = row(title: firstTitle, name: filenames[0], choose: firstButton)
        secondRow = row(title: NSTextField(labelWithString: "2. Next clip"), name: filenames[1], choose: secondButton)
        presetPicker.addItems(withTitles: EncodePreset.allCases.map(\.title))
        presetPicker.setAccessibilityLabel("Encoding preset")
        presetPicker.target = self
        presetPicker.action = #selector(updatePreset)
        keepOriginal.state = .on
        keepOriginal.title = "Keep original file"
        keepOriginal.toolTip = "Clear this option to move the source to the Trash after the export is verified."
        presetHelp.textColor = .secondaryLabelColor
        presetHelp.font = .systemFont(ofSize: 11)
        let options = NSStackView(views: [NSTextField(labelWithString: "Quality"), presetPicker])
        options.alignment = .centerY
        options.spacing = 8
        encodeOptions = stack([options, presetHelp, keepOriginal], spacing: 6)
        let choices = stack([first, secondRow, swapButton, encodeOptions], spacing: 9)

        progress.minValue = 0
        progress.maxValue = 100
        progress.controlSize = .small
        progress.isHidden = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            progress.heightAnchor.constraint(equalToConstant: 9),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 18)
        ])
        let feedback = stack([progress, status], spacing: 7)

        joinButton.keyEquivalent = "\r"
        let spacer = NSView()
        let actions = NSStackView(views: [refreshButton, spacer, revealButton, cancelButton, joinButton])
        actions.alignment = .centerY
        actions.spacing = 8
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let divider = NSBox()
        divider.boxType = .separator
        let content = stack([intro, choices, divider, feedback, actions], spacing: 17)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        let navigation = sidebar()
        navigation.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(navigation)
        root.addSubview(content)
        window.contentView = root
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: root.topAnchor),
            navigation.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 200),
            content.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 25),
            first.widthAnchor.constraint(equalTo: choices.widthAnchor),
            secondRow.widthAnchor.constraint(equalTo: choices.widthAnchor),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor),
            choices.widthAnchor.constraint(equalTo: content.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: content.widthAnchor),
            divider.widthAnchor.constraint(equalTo: content.widthAnchor),
            progress.widthAnchor.constraint(equalTo: feedback.widthAnchor),
            status.widthAnchor.constraint(equalTo: feedback.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        updatePreset()
        updateTool()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard activeJob != nil else { return true }
        status.stringValue = "Cancel the current join before closing the window."
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        activeJob == nil ? .terminateNow : .terminateCancel
    }

    private func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let view = NSStackView(views: views)
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = spacing
        return view
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let view = NSButton(title: title, target: self, action: action)
        view.bezelStyle = .rounded
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }

    private func sidebar() -> NSView {
        let surface = NSVisualEffectView()
        surface.material = .sidebar
        surface.blendingMode = .withinWindow
        surface.state = .active

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 42).isActive = true
        icon.heightAnchor.constraint(equalTo: icon.widthAnchor).isActive = true
        let name = NSTextField(labelWithString: "SpliceDesk")
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        let brand = NSStackView(views: [icon, name])
        brand.alignment = .centerY
        brand.spacing = 7

        toolButtons = VideoTool.allCases.enumerated().map { index, tool in
            let item = button(tool.rawValue, #selector(changeTool(_:)))
            item.tag = index
            item.setButtonType(.pushOnPushOff)
            item.bezelStyle = .recessed
            item.alignment = .left
            item.imagePosition = .imageLeading
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            item.font = .systemFont(ofSize: 13, weight: .medium)
            item.setAccessibilityLabel(tool.rawValue)
            return item
        }
        let tools = stack(toolButtons, spacing: 7)
        let column = stack([brand, tools], spacing: 22)
        column.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: surface.topAnchor, constant: 23),
            column.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 15),
            column.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -15),
            tools.widthAnchor.constraint(equalTo: column.widthAnchor)
        ] + toolButtons.flatMap { item in
            [item.widthAnchor.constraint(equalTo: tools.widthAnchor), item.heightAnchor.constraint(equalToConstant: 32)]
        })
        return surface
    }

    private func row(title label: NSTextField, name: NSTextField, choose: NSButton) -> NSView {
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = stack([label, name], spacing: 4)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let layout = NSStackView(views: [labels, spacer, choose])
        layout.alignment = .centerY
        layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false
        let background = NSBox()
        background.boxType = .custom
        background.borderWidth = 1
        background.borderColor = .separatorColor
        background.cornerRadius = 8
        background.fillColor = .controlBackgroundColor
        background.contentView = NSView()
        let content = background.contentView!
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            layout.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            background.heightAnchor.constraint(equalToConstant: 64)
        ])
        return background
    }

    private func updateControls() {
        let busy = activeJob != nil
        toolButtons.forEach { $0.isEnabled = !busy && !refreshing }
        firstButton.isEnabled = !busy && !refreshing
        secondButton.isEnabled = firstButton.isEnabled
        refreshButton.isEnabled = firstButton.isEnabled
        presetPicker.isEnabled = firstButton.isEnabled
        keepOriginal.isEnabled = firstButton.isEnabled
        joinButton.isEnabled = firstButton.isEnabled && isReady
        cancelButton.isHidden = !busy
        cancelButton.isEnabled = busy
        revealButton.isHidden = busy || lastResult == nil
        swapButton.isEnabled = firstButton.isEnabled && isReady
    }

    private var isReady: Bool { selected[0] != nil && (tool != .join || selected[1] != nil) }

    private func updateTool() {
        heading.stringValue = tool.rawValue
        subtitle.stringValue = tool.detail
        firstTitle.stringValue = tool == .join ? "1. First clip" : "Source video"
        secondRow.isHidden = tool != .join
        swapButton.isHidden = tool != .join
        encodeOptions.isHidden = tool != .encode
        for (index, item) in toolButtons.enumerated() {
            item.state = VideoTool.allCases[index] == tool ? .on : .off
        }
        updateControls()
    }

    @objc private func updatePreset() {
        presetHelp.stringValue = EncodePreset.allCases[presetPicker.indexOfSelectedItem].detail
    }

    @objc private func swapOrder() {
        let first = selected[0]
        setFile(selected[1], at: 0)
        setFile(first, at: 1)
    }

    @objc private func changeTool(_ sender: NSButton) {
        let next = VideoTool.allCases[sender.tag]
        if next == tool {
            sender.state = .on
            return
        }
        tool = next
        setFile(nil, at: 0)
        updateTool()
        if tool == .mute, let lastResult, FileManager.default.fileExists(atPath: lastResult.path) {
            setFile(lastResult, at: 0)
            status.stringValue = "Selected the last saved video."
            updateControls()
        } else {
            refresh()
        }
    }

    private func setFile(_ file: URL?, at index: Int) {
        selected[index] = file
        filenames[index].stringValue = file?.lastPathComponent
            ?? (index == 0 ? "Choose a video" : "Choose a video to append")
        filenames[index].toolTip = file?.path
        filenames[index].textColor = file == nil ? .secondaryLabelColor : .labelColor
    }

    @objc private func refresh() {
        guard activeJob == nil, !refreshing else { return }
        refreshing = true
        updateControls()
        let tool = self.tool
        status.stringValue = tool == .join ? "Checking Downloads and Downloads/Encoded…" : "Checking Downloads…"
        queue.async {
            let job = JoinJob()
            let latest = self.engine.latest(in: self.downloads, encoded: false,
                formats: tool == .encode ? JoinEngine.encodeExtensions : JoinEngine.extensions, job: job)
            let first = tool == .join
                ? self.engine.latest(in: self.downloads.appendingPathComponent("Encoded", isDirectory: true),
                                     encoded: true, job: job)
                : latest
            DispatchQueue.main.async {
                self.setFile(first, at: 0)
                self.setFile(tool == .join ? latest : nil, at: 1)
                self.refreshing = false
                self.status.stringValue = self.isReady
                    ? (tool == .join ? "Clips play in the order shown." : "Ready to export.")
                    : "Choose a source video to continue."
                self.updateControls()
            }
        }
    }

    @objc private func chooseFirst() { choose(0) }
    @objc private func chooseSecond() { choose(1) }

    private func choose(_ index: Int) {
        let panel = NSOpenPanel()
        panel.title = index == 0 ? "Choose a video" : "Choose the video to append"
        panel.prompt = "Choose"
        panel.directoryURL = selected[index]?.deletingLastPathComponent() ?? downloads
        let formats = tool == .encode ? JoinEngine.encodeExtensions : JoinEngine.extensions
        panel.allowedContentTypes = Array(Set(formats.compactMap { UTType(filenameExtension: $0) }))
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let file = panel.url else { return }
            self.setFile(file, at: index)
            self.status.stringValue = self.isReady ? "Ready." : "Choose the other video."
            self.updateControls()
        }
    }

    @objc private func save() {
        guard let first = selected[0], isReady, activeJob == nil else { return }
        let tool = self.tool
        let second = selected[1]
        let preset = EncodePreset.allCases[presetPicker.indexOfSelectedItem]
        let keep = keepOriginal.state == .on
        let save = NSSavePanel()
        save.title = "Export MP4"
        save.prompt = "Export"
        var folder = downloads
        if tool == .encode {
            let encoded = downloads.appendingPathComponent("Encoded", isDirectory: true)
            if (try? FileManager.default.createDirectory(at: encoded, withIntermediateDirectories: true)) != nil {
                folder = encoded
            }
        }
        save.directoryURL = folder
        save.allowedContentTypes = [.mpeg4Movie]
        save.canCreateDirectories = true
        let original = first.deletingPathExtension().lastPathComponent
        let stem = tool == .join && original.hasSuffix("-upload") ? String(original.dropLast(7)) : original
        let suffix: String
        switch tool {
        case .join: suffix = "-joined"
        case .mute: suffix = "-silent"
        case .encode: suffix = preset.suffix
        }
        var name = "\(stem)\(suffix).mp4"
        var next = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem)-\(next)\(suffix).mp4"
            next += 1
        }
        save.nameFieldStringValue = name
        save.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = save.url else { return }
            self.start(tool, first: first, second: second, destination: destination, preset: preset, keep: keep)
        }
    }

    private func start(_ tool: VideoTool, first: URL, second: URL?, destination: URL,
                       preset: EncodePreset, keep: Bool) {
        let job = JoinJob()
        activeJob = job
        lastResult = nil
        keepOriginal.state = .on
        updateControls()
        queue.async {
            do {
                let report: (String, Double?) -> Void = { phase, fraction in
                    DispatchQueue.main.async {
                        guard self.activeJob === job, self.cancelButton.isEnabled else { return }
                        self.status.stringValue = phase
                        self.progress.isHidden = false
                        self.progress.isIndeterminate = fraction == nil
                        if let fraction {
                            self.progress.doubleValue = min(100, max(0, fraction * 100))
                        } else {
                            self.progress.startAnimation(nil)
                        }
                    }
                }
                var summary = "Exported \(destination.lastPathComponent)."
                switch tool {
                case .join:
                    guard let second else { throw JoinFailure.message("Choose a second video.") }
                    try self.engine.join(first: first, second: second, destination: destination, job: job, status: report)
                case .mute:
                    try self.engine.removeAudio(from: first, destination: destination, job: job, status: report)
                case .encode:
                    summary = "Export complete. "
                        + (try self.engine.encode(first, destination: destination, preset: preset,
                                                  keep: keep, job: job, status: report))
                }
                let savedMessage = summary
                DispatchQueue.main.async {
                    self.lastResult = destination
                    if !FileManager.default.fileExists(atPath: first.path) { self.setFile(nil, at: 0) }
                    self.finish(savedMessage)
                }
            } catch JoinFailure.cancelled {
                DispatchQueue.main.async { self.finish("Cancelled.") }
            } catch {
                DispatchQueue.main.async {
                    self.finish("Could not finish.")
                    let alert = NSAlert()
                    alert.messageText = "Could not finish"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }

    private func finish(_ message: String) {
        activeJob = nil
        progress.stopAnimation(nil)
        progress.isHidden = true
        status.stringValue = message
        updateControls()
    }

    @objc private func cancel() {
        cancelButton.isEnabled = false
        status.stringValue = "Cancelling…"
        activeJob?.stop()
    }

    @objc private func reveal() {
        if let lastResult { NSWorkspace.shared.activateFileViewerSelecting([lastResult]) }
    }
}

let app = NSApplication.shared
let delegate = VideoJoiner()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
