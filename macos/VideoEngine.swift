import Foundation

enum JoinFailure: LocalizedError {
    case message(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .message(let detail): return detail
        case .cancelled: return "Join cancelled."
        }
    }
}

final class JoinJob {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw JoinFailure.cancelled }
    }

    func start(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw JoinFailure.cancelled }
        try process.run()
        self.process = process
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}

enum EncodePreset: CaseIterable {
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
        case .fastest: return "540p-class H.264 for quick uploads."
        case .balanced: return "720p-class H.264 for finer detail."
        case .highest: return "Source-resolution HEVC for maximum detail."
        }
    }

    var suffix: String {
        switch self {
        case .fastest: return "-upload"
        case .balanced: return "-balanced-upload"
        case .highest: return "-highest-quality-upload"
        }
    }
}

private struct SourceIdentity: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64
    let device: UInt64

    init(_ file: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let device = attributes[.systemNumber] as? NSNumber else {
            throw JoinFailure.message("Choose a nonempty video file.")
        }
        self.size = size.uint64Value
        self.modified = modified
        self.inode = inode.uint64Value
        self.device = device.uint64Value
    }
}

struct JoinEngine {
    static let extensions = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "mts", "m2ts", "3gp", "mpg", "mpeg"]
    static let encodeExtensions = ["mp4", "mov", "m4v"]
    let tools: URL

    private func binary(_ name: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let locations = [tools.path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for location in locations {
            let candidate = URL(fileURLWithPath: location, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw JoinFailure.message("Install FFmpeg with Homebrew (brew install ffmpeg), then try again.")
    }

    struct Media {
        let duration: Double
        let streams: [[String: Any]]

        var video: [String: Any] {
            streams.first {
                $0["codec_type"] as? String == "video"
                    && ($0["disposition"] as? [String: Int])?["attached_pic"] != 1
            } ?? [:]
        }

        var audio: [String: Any]? { streams.first { $0["codec_type"] as? String == "audio" } }
        var audioCount: Int { streams.filter { $0["codec_type"] as? String == "audio" }.count }
        var videoDuration: Double { JoinEngine.seconds(video["duration"]) ?? duration }
        var rotation: Int {
            (video["side_data_list"] as? [[String: Any]])?
                .compactMap { $0["rotation"] as? Int }.first ?? 0
        }

        var canvas: (width: Int, height: Int) {
            let width = video["width"] as? Int ?? 0
            let height = video["height"] as? Int ?? 0
            let sar = (video["sample_aspect_ratio"] as? String ?? "").split(separator: ":").compactMap { Double($0) }
            let ratio = sar.count == 2 && sar[0] > 0 && sar[1] > 0 ? sar[0] / sar[1] : 1
            let displayWidth = min(Double(width) * ratio, 8192)
            let displayHeight = min(Double(height), 8192)
            let rotated = abs(rotation % 180) == 90
            let w = rotated ? displayHeight : displayWidth
            let h = rotated ? displayWidth : displayHeight
            return (max(2, Int(w / 2) * 2), max(2, Int(h / 2) * 2))
        }

        var copySignature: [[String]]? {
            guard video["codec_name"] as? String == "h264",
                  video["extradata_hash"] != nil,
                  streams.count == (audio == nil ? 1 : 2),
                  audio == nil || (audio?["codec_name"] as? String == "aac" && audio?["extradata_hash"] != nil)
            else { return nil }
            let keys = ["codec_type", "codec_name", "extradata_hash", "time_base", "width", "height", "pix_fmt",
                        "sample_aspect_ratio", "field_order", "color_range", "color_space", "color_transfer",
                        "color_primaries", "sample_rate", "channels", "channel_layout"]
            return streams.map { stream in
                keys.map { stream[$0].map { String(describing: $0) } ?? "" }
            } + [[String(rotation)]]
        }
    }

    private static func seconds(_ value: Any?) -> Double? {
        guard let string = value as? String, let number = Double(string), number.isFinite, number > 0 else {
            return nil
        }
        return number
    }

    private func run(_ binary: URL, _ args: [String], job: JoinJob,
                     progress: ((Double) -> Void)? = nil) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            throw JoinFailure.message("Could not create a temporary log.")
        }
        defer { try? FileManager.default.removeItem(at: errorURL) }
        let log = try FileHandle(forWritingTo: errorURL)
        defer { try? log.close() }
        process.executableURL = binary
        process.arguments = args
        process.standardOutput = output
        process.standardError = log
        try job.start(process)
        try output.fileHandleForWriting.close()

        var result = Data()
        var pending = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if let progress {
                pending.append(chunk)
                while let newline = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    pending.removeSubrange(...newline)
                    if line.hasPrefix("out_time_us="), let microseconds = Double(line.dropFirst(12)) {
                        progress(microseconds / 1_000_000)
                    } else if line.hasPrefix("avconvert progress:"),
                              let amount = line.dropFirst(19).split(separator: "%").first,
                              let percent = Double(amount.trimmingCharacters(in: .whitespaces)) {
                        progress(percent / 100)
                    }
                }
            } else {
                result.append(chunk)
            }
        }
        process.waitUntilExit()
        try job.check()
        if process.terminationStatus != 0 {
            let reader = try FileHandle(forReadingFrom: errorURL)
            defer { try? reader.close() }
            let size = try reader.seekToEnd()
            try reader.seek(toOffset: size > 2000 ? size - 2000 : 0)
            let detail = String(decoding: try reader.readToEnd() ?? Data(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw JoinFailure.message(detail.isEmpty ? "\(binary.lastPathComponent) could not finish." : detail)
        }
        return result
    }

    func probe(_ url: URL, job: JoinJob) throws -> Media {
        let data = try run(binary("ffprobe"), [
            "-v", "error", "-protocol_whitelist", "file,pipe", "-show_streams", "-show_format",
            "-show_data_hash", "sha256", "-of", "json", url.path
        ], job: job)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = root["format"] as? [String: Any],
              let duration = Self.seconds(format["duration"]),
              let streams = root["streams"] as? [[String: Any]] else {
            throw JoinFailure.message("Could not read the duration of \(url.lastPathComponent).")
        }
        let media = Media(duration: duration, streams: streams)
        guard media.video["index"] is Int,
              (media.video["width"] as? Int ?? 0) > 0,
              (media.video["height"] as? Int ?? 0) > 0 else {
            throw JoinFailure.message("No video track was found in \(url.lastPathComponent).")
        }
        return media
    }

    func latest(in folder: URL, encoded: Bool, formats: [String] = Self.extensions, job: JoinJob) -> URL? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles
        )) ?? []
        let candidates = files.compactMap { file -> (URL, Date)? in
            let stem = file.deletingPathExtension().lastPathComponent.lowercased()
            guard formats.contains(file.pathExtension.lowercased()),
                  !stem.hasSuffix("-joined"), !stem.hasSuffix("-silent"),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true
            else { return nil }
            if !encoded && stem.hasSuffix("-upload") {
                return nil
            }
            return (file, values.contentModificationDate ?? .distantPast)
        }
        let sorted = candidates.sorted(by: { ($0.1, $0.0.lastPathComponent) > ($1.1, $1.0.lastPathComponent) })
        if (try? binary("ffprobe")) == nil { return sorted.first?.0 }
        for (file, _) in sorted {
            if (try? job.check()) == nil { return nil }
            if (try? probe(file, job: job)) != nil { return file }
        }
        return nil
    }

    private func ffmpeg(_ args: [String], job: JoinJob, progress: @escaping (Double) -> Void) throws {
        _ = try run(binary("ffmpeg"),
                    ["-hide_banner", "-loglevel", "error", "-nostdin", "-xerror",
                     "-stats_period", "0.2", "-progress", "pipe:1"] + args,
                    job: job, progress: progress)
    }

    func removeAudio(from source: URL, destination: URL, job: JoinJob,
                     status: @escaping (String, Double?) -> Void) throws {
        let input = try probe(source, job: job)
        let index = input.video["index"] as? Int ?? 0
        let codec = input.video["codec_name"] as? String
        let copy = codec == "h264" || codec == "hevc" || codec == "av1" || codec == "mpeg4"
        let video = copy ? ["-c:v", "copy"]
            : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
               "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p", "-fps_mode:v", "passthrough"]
        let tag = codec == "hevc" ? ["-tag:v", "hvc1"] : []
        let title = copy ? "Removing audio…" : "Converting to a silent MP4…"
        try saveEdit(to: destination, job: job) { output in
            status(title, 0)
            try ffmpeg(["-protocol_whitelist", "file,pipe", "-i", source.path, "-map", "0:\(index)"] + video + tag
                + ["-movflags", "+faststart", "-n", output.path], job: job) {
                status(title, $0 / input.videoDuration)
            }
            let verified = try verify(output, duration: input.videoDuration, audioCount: 0, job: job, status: status)
            if copy, let expected = input.video["nb_frames"] as? String,
               let actual = verified.video["nb_frames"] as? String, actual != expected {
                throw JoinFailure.message("The silent copy did not pass the frame count check.")
            }
        }
    }

    func encode(_ source: URL, destination: URL, preset: EncodePreset, keep: Bool, job: JoinJob,
                status: @escaping (String, Double?) -> Void) throws -> String {
        let identity = try SourceIdentity(source)
        guard try !isTransferring(source, job: job) else {
            throw JoinFailure.message("LocalSend still has this file open. Try again after the transfer finishes.")
        }
        let input = try probe(source, job: job)
        var size = identity.size
        try saveEdit(to: destination, job: job) { output in
            status("Encoding…", 0)
            _ = try run(URL(fileURLWithPath: "/usr/bin/avconvert"),
                        ["--source", source.path, "--output", output.path, "--preset", preset.command, "--progress"],
                        job: job) { status("Encoding…", $0) }
            size = try SourceIdentity(output).size
            guard size < identity.size else {
                throw JoinFailure.message("This preset did not produce a smaller file. Try Fastest or Balanced.")
            }
            try verify(output, duration: input.duration, audioCount: input.audioCount, job: job, status: status)
            guard try SourceIdentity(source) == identity else {
                throw JoinFailure.message("The source changed during encoding. Try again after the transfer finishes.")
            }
        }
        let reduction = Int((1 - Double(size) / Double(identity.size)) * 100)
        guard !keep else { return "\(reduction)% smaller." }
        guard (try? isTransferring(source, job: job)) == false,
              (try? SourceIdentity(source)) == identity else {
            return "\(reduction)% smaller. The source changed and was kept."
        }
        do {
            try FileManager.default.trashItem(at: source, resultingItemURL: nil)
            return "\(reduction)% smaller. Original moved to the Trash."
        } catch {
            return "\(reduction)% smaller. The original could not be moved to the Trash."
        }
    }

    private func isTransferring(_ source: URL, job: JoinJob) throws -> Bool {
        let lookup = Process()
        lookup.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lookup.arguments = ["-a", "-c", "LocalSend", source.path]
        lookup.standardOutput = FileHandle.nullDevice
        lookup.standardError = FileHandle.nullDevice
        try job.start(lookup)
        lookup.waitUntilExit()
        try job.check()
        return lookup.terminationStatus == 0
    }

    private func saveEdit(to destination: URL, job: JoinJob, write: (URL) throws -> Void) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw JoinFailure.message("A file already has that name. Choose a new name.")
        }
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent(".video-edit-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("video.mp4")
        try write(output)
        try job.check()
        try files.moveItem(at: output, to: destination)
    }

    func join(first: URL, second: URL, destination: URL, job: JoinJob,
              status: @escaping (String, Double?) -> Void) throws {
        let manager = FileManager.default
        let firstValues = try first.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let secondValues = try second.resourceValues(forKeys: [.fileResourceIdentifierKey])
        let sameFile = (firstValues.fileResourceIdentifier as? NSObject)
            .map { $0 == secondValues.fileResourceIdentifier as? NSObject } ?? false
        guard !sameFile, first.resolvingSymlinksInPath() != second.resolvingSymlinksInPath() else {
            throw JoinFailure.message("Choose two different videos.")
        }
        guard !manager.fileExists(atPath: destination.path) else {
            throw JoinFailure.message("A file already has that name. Choose a new name for the joined video.")
        }

        status("Checking both videos…", nil)
        let a = try probe(first, job: job)
        let b = try probe(second, job: job)
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent(".video-join-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent("joined.mp4")

        func compatible(_ tail: Media) -> Bool {
            a.copySignature.map { $0 == tail.copySignature } ?? false
        }

        func copy(_ tailFile: URL, _ tail: Media) throws {
            let paths = [first.path, tailFile.path]
            guard paths.allSatisfy({ !$0.contains(where: { $0.isNewline }) }) else {
                throw JoinFailure.message("These filenames require converting the videos.")
            }
            let manifest = scratch.appendingPathComponent("join.ffconcat")
            let lines = paths.map { "file '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            try (["ffconcat version 1.0"] + lines + [""]).joined(separator: "\n")
                .write(to: manifest, atomically: true, encoding: .utf8)
            let expected = a.duration + tail.duration
            let input = ["-protocol_whitelist", "file,pipe", "-f", "concat", "-safe", "0", "-i", manifest.path,
                         "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "copy"]
            let ending = ["-movflags", "+faststart", "-n", output.path]
            do {
                let title = "Joining without re-encoding…"
                status(title, 0)
                try ffmpeg(input + ["-c:a", "copy"] + ending, job: job) { status(title, $0 / expected) }
            } catch {
                try job.check()
                guard a.audio != nil else { throw error }
                if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
                // AAC encoder delay can cause overlapping packet timestamps at the splice.
                let title = "Joining video and aligning audio…"
                status(title, 0)
                try ffmpeg(input + ["-af", "aresample=async=1:first_pts=0", "-c:a", "aac", "-b:a", "128k"] + ending,
                           job: job) { status(title, $0 / expected) }
            }
            try verify(output, duration: expected, audioCount: a.audioCount, job: job, status: status)
        }

        // The matching Apple presets can preserve the longer first clip byte-for-byte.
        func applePreset() -> String? {
            guard a.copySignature != nil, a.rotation == 0,
                  a.video["width"] as? Int != b.video["width"] as? Int
                    || a.video["height"] as? Int != b.video["height"] as? Int else { return nil }
            switch max(a.canvas.width, a.canvas.height) {
            case 960: return "Preset960x540"
            case 1280: return "Preset1280x720"
            default: return nil
            }
        }

        do {
            if compatible(b) {
                try copy(second, b)
            } else if let preset = applePreset() {
                status("Matching the second clip to the first…", nil)
                let tailFile = scratch.appendingPathComponent("tail.mp4")
                _ = try run(URL(fileURLWithPath: "/usr/bin/avconvert"),
                            ["--source", second.path, "--preset", preset, "--output", tailFile.path], job: job)
                let tail = try probe(tailFile, job: job)
                guard compatible(tail), abs(tail.duration - b.duration) <= 0.5 else {
                    throw JoinFailure.message("The clips need a common format.")
                }
                try copy(tailFile, tail)
            } else {
                throw JoinFailure.message("The clips need a common format.")
            }
        } catch {
            try job.check()
            if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
            try normalize(first: first, second: second, a: a, b: b, output: output, job: job, status: status)
        }

        try job.check()
        try manager.moveItem(at: output, to: destination)
    }

    private func normalize(first: URL, second: URL, a: Media, b: Media, output: URL, job: JoinJob,
                           status: @escaping (String, Double?) -> Void) throws {
        guard ![a, b].contains(where: { ["smpte2084", "arib-std-b67"].contains($0.video["color_transfer"] as? String ?? "") }) else {
            throw JoinFailure.message("These HDR clips need conversion before they can be joined. Choose two matching clips or convert them to SDR first.")
        }
        let canvas = a.canvas
        let audio = a.audio != nil || b.audio != nil
        let expected = a.videoDuration + b.videoDuration
        var filters: [String] = []
        for (input, media) in [a, b].enumerated() {
            let video = media.video["index"] as? Int ?? 0
            let sourceCanvas = media.canvas
            let scale = min(Double(canvas.width) / Double(sourceCanvas.width),
                            Double(canvas.height) / Double(sourceCanvas.height))
            let width = max(2, Int(Double(sourceCanvas.width) * scale / 2) * 2)
            let height = max(2, Int(Double(sourceCanvas.height) * scale / 2) * 2)
            let transform = "scale=\(width):\(height),setsar=1,pad=\(canvas.width):\(canvas.height):(ow-iw)/2:(oh-ih)/2"
            filters.append("[\(input):\(video)]\(transform),format=yuv420p,settb=AVTB,setpts=PTS-STARTPTS[v\(input)]")
            if audio {
                let source = (media.audio?["index"] as? Int).map {
                    "[\(input):\($0)]aresample=48000:async=1:first_pts=0,aformat=channel_layouts=stereo,apad"
                } ?? "anullsrc=r=48000:cl=stereo"
                filters.append("\(source),atrim=duration=\(media.videoDuration),asetpts=PTS-STARTPTS[a\(input)]")
            }
        }
        filters.append(audio ? "[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]" : "[v0][v1]concat=n=2:v=1:a=0[v]")
        let common = ["-protocol_whitelist", "file,pipe", "-i", first.path,
                      "-protocol_whitelist", "file,pipe", "-i", second.path, "-filter_complex", filters.joined(separator: ";"),
                      "-map", "[v]", "-fps_mode:v", "passthrough", "-enc_time_base:v", "1:1000000"]
            + (audio ? ["-map", "[a]", "-c:a", "aac", "-b:a", "128k"] : [])
        let bitrate = max(900, Int(Double(canvas.width * canvas.height) * 0.004))
        let ending = ["-movflags", "+faststart", "-n", output.path]
        let title = "Converting and joining both clips…"
        status(title, 0)
        do {
            try ffmpeg(common + ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)k"] + ending, job: job) {
                status(title, $0 / expected)
            }
        } catch {
            try job.check()
            if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
            status(title, 0)
            try ffmpeg(common + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "22"] + ending, job: job) {
                status(title, $0 / expected)
            }
        }
        try verify(output, duration: expected, audioCount: audio ? 1 : 0, job: job, status: status)
    }

    @discardableResult
    private func verify(_ file: URL, duration: Double, audioCount: Int, job: JoinJob,
                        status: @escaping (String, Double?) -> Void) throws -> Media {
        let output = try probe(file, job: job)
        guard abs(output.duration - duration) <= 1,
              abs(output.videoDuration - duration) <= 1,
              output.audioCount == audioCount else {
            throw JoinFailure.message("The joined file did not pass the duration and track checks.")
        }
        let title = "Verifying the video…"
        status(title, 0)
        try ffmpeg(["-err_detect", "explode", "-protocol_whitelist", "file,pipe", "-i", file.path,
                    "-map", "0:v:0", "-map", "0:a?",
                    "-fps_mode:v", "passthrough", "-enc_time_base:v", "1:1000000", "-f", "null", "-"],
                   job: job) { status(title, $0 / duration) }
        return output
    }
}
