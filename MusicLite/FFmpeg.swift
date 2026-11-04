import Foundation

/// Formats AVFoundation cannot play (WMA, WavPack, TTA, APE, Matroska, DSD, Ogg Vorbis…)
/// are decoded once by ffmpeg into a temporary ALAC file, which AVFoundation then plays.
/// ALAC keeps the original bit depth and sample rate. Not FLAC: ffmpeg carries the source's
/// frame size over (46080 samples from TTA) and AVFoundation refuses such a FLAC.
enum FFmpeg {
    enum Failure: LocalizedError {
        case missing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .missing: "Ten format gram przez ffmpeg, a go nie ma. Zainstaluj: brew install ffmpeg"
            case .failed(let message): message
            }
        }
    }

    static let ffmpeg = ["/opt/homebrew/bin/", "/usr/local/bin/", "/opt/local/bin/"].map { $0 + "ffmpeg" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Temporary files are named `MusicLite-<pid>-<uuid>.caf`. The PID tells a later launch
    /// which files belong to a MusicLite that is gone (killed while ffmpeg worked).
    static let prefix = "MusicLite-"

    /// Cancelling the calling task stops ffmpeg and removes the half-written file.
    static func decode(_ url: URL) async throws -> URL {
        guard let ffmpeg else { throw Failure.missing }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(getpid())-\(UUID().uuidString).caf")
        // First audio stream only: a WMV or MKV may carry video and several sound tracks.
        let args = ["-nostdin", "-loglevel", "error", "-i", url.path, "-map", "0:a:0",
                    "-c:a", "alac", out.path]
        let result: (err: String, status: Int32)
        do {
            result = try await Shell.run(ffmpeg, args)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        guard result.status == 0, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: out)
            if Task.isCancelled { throw CancellationError() }
            let line = result.err.split(separator: "\n").last.map(String.init)
            throw Failure.failed(line ?? "ffmpeg nie odczytał tego pliku.")
        }
        return out
    }

    /// Removes temporary files of MusicLite processes that no longer run, and this
    /// process's own too when `includingOwn` (the app is quitting). A killed MusicLite
    /// cannot clean up; its ffmpeg may still write, but to a file no longer on disk.
    static func removeTemporaryFiles(includingOwn: Bool = false) {
        let dir = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".caf") {
            // Names from before 0.1.3 have no PID: the first UUID group does not parse or
            // names no running process, so they go too.
            let pid = name.dropFirst(prefix.count).split(separator: "-").first.flatMap { Int32($0) }
            if let pid {
                let own = pid == getpid()
                if own && !includingOwn { continue }
                if !own && (kill(pid, 0) == 0 || errno == EPERM) { continue }
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

enum Shell {
    /// Cancelling the calling task terminates the process; the result then carries its
    /// non-zero exit status.
    static func run(_ path: String, _ args: [String]) async throws -> (err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        // Launched before the cancellation handler exists: terminate() on a process that
        // never started raises an exception.
        try process.run()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Read before waiting: a full pipe would block ffmpeg forever.
                    let errData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let errText = String(decoding: errData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(returning: (errText, process.terminationStatus))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
