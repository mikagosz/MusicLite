import SwiftUI
import UniformTypeIdentifiers

struct MusicLiteApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ObservedObject private var playlists = Playlists.shared

    var body: some Scene {
        Window("MusicLite", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    if let urls = Self.pick(title: String(localized: "Open")) { Player.shared.open(urls) }
                }
                .keyboardShortcut("o")
                Button("Add to List…") {
                    if let urls = Self.pick(title: String(localized: "Add to List")) { Player.shared.add(urls) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Save List as Playlist…") { playlists.saveCurrent() }
                    .keyboardShortcut("s")
            }
            CommandMenu("Playlists") {
                if playlists.names.isEmpty {
                    Text("No Saved Playlists")
                }
                ForEach(playlists.names, id: \.self) { name in
                    Button(name) { playlists.open(name) }
                }
                Divider()
                Button("Show Playlists Folder in Finder") {
                    try? FileManager.default.createDirectory(at: playlists.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(playlists.folder)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Make MusicLite the Default Music Player") { Task { await DefaultApp.claimFromMenu() } }
            }
        }
    }

    /// Songs and folders (a folder brings the songs straight in it).
    static func pick(title: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = title
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audio, .movie] + DefaultApp.types
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder's "open" (double click, Open With, dropping on the Dock icon).
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Player.shared.open(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Player.shared.stop() }
    }
}

/// Makes MusicLite what Finder opens on double click, for the formats in `extensions`.
enum DefaultApp {
    /// No MIDI (needs a synthesizer, ffmpeg cannot decode it) and no m4b (audiobooks stay in Books).
    static let extensions = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "wma", "wmv", "asf",
        "ogg", "oga", "opus", "ape", "wv", "mka", "dsf", "dff", "ac3", "eac3", "amr", "mp2",
        "mpc", "tta", "au",
    ]

    static var types: [UTType] {
        var seen = Set<String>()
        return extensions.compactMap { UTType(filenameExtension: $0) }
            .filter { !$0.isDynamic && seen.insert($0.identifier).inserted }
    }

    /// The formats Finder does not open with MusicLite yet. Only these are asked for:
    /// macOS confirms each format that already has an app in a dialog of its own.
    static var missing: [UTType] {
        types.filter { type in
            let app = NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Bundle(url: $0)?.bundleIdentifier }
            return app != Bundle.main.bundleIdentifier
        }
    }

    /// Returns the formats that failed, with the reason. A format refused in macOS's dialog
    /// comes back here as failed. The older LSSetDefaultRoleHandlerForContentType asks too
    /// and reports success before the answer.
    static func claim(_ types: [UTType]) async -> [String] {
        var failed: [String] = []
        for type in types {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
            } catch {
                failed.append("\(type.identifier): \(error.localizedDescription)")
            }
        }
        return failed
    }

    @MainActor private static var isClaiming = false

    @MainActor
    static func claimFromMenu() async {
        guard !isClaiming else { return }
        let todo = missing
        guard !todo.isEmpty else {
            alert(String(localized: "MusicLite already opens every music format."),
                  String(localized: "Formats: \(types.count)."))
            return
        }
        let ask = NSAlert()
        ask.messageText = String(localized: "Make MusicLite the default? Formats to change: \(todo.count).")
        ask.informativeText = String(localized: """
            macOS may ask about each one in a separate dialog — click Use “MusicLite” there. \
            Formats MusicLite already opens are skipped.
            """) + "\n\n" + todo.map { $0.preferredFilenameExtension ?? $0.identifier }.joined(separator: ", ")
        ask.addButton(withTitle: String(localized: "Set"))
        ask.addButton(withTitle: String(localized: "Cancel"))
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        isClaiming = true
        defer { isClaiming = false }
        let failed = await claim(todo)
        alert(failed.isEmpty
              ? String(localized: "Done. Formats changed: \(todo.count).")
              : String(localized: "Failed for \(failed.count) of \(todo.count) formats."),
              failed.joined(separator: "\n"))
    }

    @MainActor
    private static func alert(_ message: String, _ details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }
}
