import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct EncodeError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct FileIdentity: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64
    let device: UInt64

    init(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else {
            throw EncodeError("Select a nonempty video file.")
        }
        self.size = size.uint64Value
        self.modified = modified
        self.inode = inode.uint64Value
        self.device = device.uint64Value
    }
}

enum Preset: CaseIterable {
    case fastest, balanced, highest

    var title: String {
        switch self {
        case .fastest: return "Fastest"
        case .balanced: return "Balanced"
        case .highest: return "Highest Quality"
        }
    }

    var command: String {
        switch self {
        case .fastest: return "Preset960x540"
        case .balanced: return "Preset1280x720"
        case .highest: return "PresetHEVCHighestQuality"
        }
    }

    var detail: String {
        switch self {
        case .fastest: return "540p-class H.264 for a quick, smaller upload."
        case .balanced: return "720p-class H.264 for more detail."
        case .highest: return "HEVC at source resolution for the most detail."
        }
    }

    var suffix: String {
        switch self {
        case .fastest: return "-upload.mp4"
        case .balanced: return "-balanced-upload.mp4"
        case .highest: return "-highest-quality-upload.mp4"
        }
    }
}

final class EncodeJob {
    private let lock = NSLock()
    private var cancelled = false
    private var finalizing = false
    private var encoder: Process?

    func cancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finalizing else { return false }
        cancelled = true
        if let encoder, encoder.isRunning { encoder.terminate() }
        return true
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }

    func runEncoder(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try process.run()
        encoder = process
    }

    func beginFinalizing() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        finalizing = true
    }
}

final class EncoderWindow: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let selection = NSTextField(wrappingLabelWithString: "No video selected")
    private let presetPicker = NSPopUpButton()
    private let presetDetail = NSTextField(wrappingLabelWithString: Preset.fastest.detail)
    private let status = NSTextField(labelWithString: "Ready")
    private let detail = NSTextField(wrappingLabelWithString: "Click Encode to start.")
    private let progress = NSProgressIndicator()
    private var chooseButton: NSButton!
    private var refreshButton: NSButton!
    private var keepOriginal: NSButton!
    private var encodeButton: NSButton!
    private var cancelButton: NSButton!
    private var outputButton: NSButton!
    private var selectedFile: URL?
    private var manuallySelected = false
    private var job: EncodeJob?

    private var downloads: URL {
        #if ENCODER_TEST
        if let path = Bundle.main.object(forInfoDictionaryKey: "EncoderTestDownloads") as? String {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }
    private var outputFolder: URL { downloads.appendingPathComponent("Encoded", isDirectory: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 346),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "LocalSend Encoder"
        window.isReleasedWhenClosed = false
        window.center()

        let fileLabel = NSTextField(labelWithString: "Source video")
        fileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        selection.maximumNumberOfLines = 2
        selection.lineBreakMode = .byTruncatingMiddle
        chooseButton = NSButton(title: "Choose File…", target: self, action: #selector(chooseFile))
        refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshSelection))
        refreshButton.toolTip = "Select the newest video in Downloads."
        let fileRow = row([selection, refreshButton, chooseButton])
        selection.setContentHuggingPriority(.defaultLow, for: .horizontal)
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        presetPicker.addItems(withTitles: Preset.allCases.map(\.title))
        presetPicker.target = self
        presetPicker.action = #selector(presetChanged)
        presetPicker.selectItem(at: 0)
        presetPicker.setAccessibilityLabel("Encoding preset")
        let presetRow = row([NSTextField(labelWithString: "Encoding preset"), presetPicker, spacer()])
        presetDetail.textColor = .secondaryLabelColor

        keepOriginal = NSButton(checkboxWithTitle: "Keep Original", target: self, action: #selector(keepChanged))
        keepOriginal.state = .on
        keepOriginal.toolTip = "When unchecked, the verified original moves to the Trash."
        status.font = .systemFont(ofSize: 16, weight: .semibold)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        progress.minValue = 0
        progress.maxValue = 100
        progress.isIndeterminate = false
        progress.style = .bar

        encodeButton = NSButton(title: "Encode", target: self, action: #selector(encodeSelected))
        encodeButton.keyEquivalent = "\r"
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelEncode))
        outputButton = NSButton(title: "Open Encoded Folder", target: self, action: #selector(openEncodedFolder))
        let actions = row([outputButton, spacer(), cancelButton, encodeButton])
        let stack = NSStackView(views: [fileLabel, fileRow, presetRow, presetDetail, keepOriginal,
                                       status, detail, progress, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(18, after: keepOriginal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            fileRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            presetDetail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshLatest()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if job == nil {
            if !hasVisibleWindows {
                manuallySelected = false
                presetPicker.selectItem(at: 0)
                presetChanged()
            }
            if !manuallySelected { refreshLatest() }
        }
        window?.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        job == nil ? .terminateNow : .terminateCancel
    }

    @objc private func openEncodedFolder() { NSWorkspace.shared.open(outputFolder) }

    @objc private func presetChanged() {
        presetDetail.stringValue = Preset.allCases[presetPicker.indexOfSelectedItem].detail
    }

    @objc private func keepChanged() {
        if job == nil, status.stringValue == "Ready" { detail.stringValue = cleanupDescription }
    }

    private var cleanupDescription: String {
        keepOriginal.state == .on ? "The original will stay in place." : "After verification, the original moves to the Trash."
    }

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video to encode"
        panel.directoryURL = selectedFile?.deletingLastPathComponent() ?? downloads
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "m4v") ?? .movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.manuallySelected = true
            self.select(url)
        }
    }

    @objc private func refreshSelection() {
        guard job == nil else { return }
        manuallySelected = false
        refreshLatest()
    }

    private func refreshLatest() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: downloads, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            let candidates = files.compactMap { url -> (URL, FileIdentity)? in
                guard ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()),
                      let identity = try? FileIdentity(url) else { return nil }
                return (url, identity)
            }
            let latest = candidates.max { ($0.1.modified, $0.0.path) < ($1.1.modified, $1.0.path) }
            select(latest?.0)
        } catch {
            select(nil)
            detail.stringValue = "Downloads couldn’t be read. Use Choose File to select a video."
        }
    }

    private func select(_ url: URL?) {
        selectedFile = url
        selection.stringValue = url?.lastPathComponent ?? "No video selected"
        selection.toolTip = url?.path
        status.stringValue = url == nil ? "Choose a video" : "Ready"
        detail.stringValue = url == nil ? "Supported files are MP4, MOV, and M4V." : cleanupDescription
        progress.doubleValue = 0
        updateControls()
    }

    private func updateControls() {
        let idle = job == nil
        chooseButton.isEnabled = idle
        refreshButton.isEnabled = idle
        presetPicker.isEnabled = idle
        keepOriginal.isEnabled = idle
        encodeButton.isEnabled = idle && selectedFile != nil
        cancelButton.isEnabled = !idle
        outputButton.isEnabled = FileManager.default.fileExists(atPath: outputFolder.path)
    }

    @objc private func encodeSelected() {
        guard job == nil, let source = selectedFile else { return }
        let preset = Preset.allCases[presetPicker.indexOfSelectedItem]
        let keep = keepOriginal.state == .on
        let folder = outputFolder
        let job = EncodeJob()
        self.job = job
        updateControls()
        progress.doubleValue = 0
        status.stringValue = "Preparing…"
        detail.stringValue = source.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let message = try self.encode(source, to: folder, preset: preset, keep: keep, job: job)
                self.finish("Ready to upload", detail: message, success: true)
            } catch is CancellationError {
                self.finish("Canceled", detail: "The original was kept.", success: false)
            } catch {
                self.finish("Couldn’t finish", detail: error.localizedDescription, success: false)
            }
        }
    }

    @objc private func cancelEncode() {
        guard let job, job.cancel() else { return }
        cancelButton.isEnabled = false
        status.stringValue = "Canceling…"
    }

    private func update(_ message: String, percent: Double) {
        DispatchQueue.main.async {
            guard self.cancelButton.isEnabled else { return }
            self.status.stringValue = message
            self.progress.doubleValue = max(0, min(100, percent))
        }
    }

    private func finish(_ message: String, detail: String, success: Bool) {
        DispatchQueue.main.async {
            self.job = nil
            self.status.stringValue = message
            self.detail.stringValue = detail
            self.progress.doubleValue = success ? 100 : 0
            if let selected = self.selectedFile, !FileManager.default.fileExists(atPath: selected.path) {
                self.manuallySelected = false
                self.selectedFile = nil
                self.selection.stringValue = "No video selected"
                self.selection.toolTip = nil
            }
            self.updateControls()
        }
    }

    private func encode(_ source: URL, to folder: URL, preset: Preset, keep: Bool, job: EncodeJob) throws -> String {
        let files = FileManager.default
        let identity = try FileIdentity(source)
        try checkTransfer(source)
        try job.checkCancellation()
        let output = folder.appendingPathComponent(source.deletingPathExtension().lastPathComponent + preset.suffix)
        guard !files.fileExists(atPath: output.path) else {
            throw EncodeError("This preset’s output already exists. Open Encoded Folder to find it.")
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appendingPathComponent(".video-encode-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let copy = staging.appendingPathComponent("upload.mp4")
        try convert(source, to: copy, preset: preset, job: job)
        update("Verifying video and audio…", percent: 0)
        let verified = try verify(copy, original: source, sourceSize: identity.size, job: job)
        guard try FileIdentity(source) == identity else {
            throw EncodeError("The source changed during encoding. The original was kept.")
        }
        try job.beginFinalizing()
        DispatchQueue.main.async {
            self.cancelButton.isEnabled = false
            self.status.stringValue = "Saving verified copy…"
        }
        try files.moveItem(at: copy, to: output)
        guard try FileIdentity(output) == verified else {
            throw EncodeError("The saved copy changed after verification. The original was kept.")
        }
        let reduction = Int((1 - Double(verified.size) / Double(identity.size)) * 100)
        if keep { return "\(reduction)% smaller. Original kept." }
        guard try FileIdentity(source) == identity else {
            throw EncodeError("The verified copy was saved. The original changed and was kept.")
        }
        do {
            try files.trashItem(at: source, resultingItemURL: nil)
        } catch {
            throw EncodeError("The verified copy was saved. The original couldn’t be moved to the Trash.")
        }
        return "\(reduction)% smaller. Original moved to the Trash."
    }

    private func checkTransfer(_ source: URL) throws {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lookup.arguments = ["-a", "-c", "LocalSend", source.path]
        lookup.standardOutput = FileHandle.nullDevice
        lookup.standardError = FileHandle.nullDevice
        try lookup.run()
        lookup.waitUntilExit()
        if lookup.terminationStatus == 0 {
            throw EncodeError("LocalSend still has this file open. Try again after the transfer finishes.")
        }
    }

    private func convert(_ source: URL, to copy: URL, preset: Preset, job: EncodeJob) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/avconvert")
        process.arguments = ["--source", source.path, "--output", copy.path, "--preset", preset.command, "--progress"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try job.runEncoder(process)
        try pipe.fileHandleForWriting.close()

        let pattern = try NSRegularExpression(pattern: #"avconvert progress:\s*([0-9.]+)%"#)
        var buffer = Data()
        var lastError = "The encoder exited before producing a copy."
        var percent = -1.0
        func processLine(_ bytes: Data) {
            let line = String(decoding: bytes, as: UTF8.self)
            if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line),
               let parsed = Double(line[range]), parsed > percent {
                percent = parsed
                if parsed >= 94.9 { update("Finishing MP4…", percent: parsed) }
                else { update("Encoding… \(Int(parsed))%", percent: parsed) }
            } else if !line.isEmpty && !line.hasPrefix("avconvert progress:") {
                lastError = line
            }
        }
        while let bytes = try pipe.fileHandleForReading.read(upToCount: 8192), !bytes.isEmpty {
            buffer.append(bytes)
            while let end = buffer.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                processLine(Data(buffer[..<end]))
                buffer.removeSubrange(...end)
            }
        }
        processLine(buffer)
        process.waitUntilExit()
        try job.checkCancellation()
        guard process.terminationStatus == 0 else { throw EncodeError(lastError) }
    }

    private func verify(_ copy: URL, original: URL, sourceSize: UInt64, job: EncodeJob) throws -> FileIdentity {
        let identity = try FileIdentity(copy)
        guard identity.size < sourceSize else {
            throw EncodeError("This preset didn’t produce a smaller file. Try a faster preset. The original was kept.")
        }
        let source = AVURLAsset(url: original)
        let result = AVURLAsset(url: copy)
        let duration = result.duration.seconds
        let sourceDuration = source.duration.seconds
        guard duration.isFinite, sourceDuration.isFinite, duration > 0,
              abs(duration - sourceDuration) <= 1 else {
            throw EncodeError("The encoded duration doesn’t match the original.")
        }
        let videos = result.tracks(withMediaType: .video)
        let audio = result.tracks(withMediaType: .audio)
        guard !videos.isEmpty,
              videos.count == source.tracks(withMediaType: .video).count,
              audio.count == source.tracks(withMediaType: .audio).count else {
            throw EncodeError("The encoded copy is missing a video or audio track.")
        }
        for video in videos {
            try decode(result, track: video, settings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ], job: job) { seconds in
                let percent = min(99, max(0, 100 * seconds / duration))
                self.update("Verifying video… \(Int(percent))%", percent: percent)
            }
        }
        update("Verifying audio…", percent: 99)
        for track in audio {
            try decode(result, track: track, settings: [AVFormatIDKey: kAudioFormatLinearPCM], job: job) { _ in }
        }
        guard try FileIdentity(copy) == identity else {
            throw EncodeError("The encoded copy changed during verification.")
        }
        return identity
    }

    private func decode(_ asset: AVAsset, track: AVAssetTrack, settings: [String: Any], job: EncodeJob,
                        progress: (Double) -> Void) throws {
        try job.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        defer { if reader.status == .reading { reader.cancelReading() } }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EncodeError("A track could not be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EncodeError("Verification couldn’t start.") }
        var samples = 0
        while try autoreleasepool(invoking: {
            if samples % 24 == 0 { try job.checkCancellation() }
            guard let sample = output.copyNextSampleBuffer() else { return false }
            guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample) else {
                throw EncodeError("The encoded copy contains an invalid media sample.")
            }
            samples += 1
            if samples % 120 == 0 {
                let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if seconds.isFinite { progress(seconds) }
            }
            return true
        }) {}
        guard reader.status == .completed, samples > 0 else {
            throw reader.error ?? EncodeError("A track failed to decode. The original was kept.")
        }
    }
}

let app = NSApplication.shared
let delegate = EncoderWindow()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
