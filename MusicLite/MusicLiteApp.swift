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
                Button("Otwórz…") {
                    if let urls = Self.pick(title: "Otwórz") { Player.shared.open(urls) }
                }
                .keyboardShortcut("o")
                Button("Dodaj do listy…") {
                    if let urls = Self.pick(title: "Dodaj do listy") { Player.shared.add(urls) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("Zapisz listę jako playlistę…") { playlists.saveCurrent() }
                    .keyboardShortcut("s")
            }
            CommandMenu("Playlisty") {
                if playlists.names.isEmpty {
                    Text("Brak zapisanych playlist")
                }
                ForEach(playlists.names, id: \.self) { name in
                    Button(name) { playlists.open(name) }
                }
                Divider()
                Button("Pokaż folder playlist w Finderze") {
                    try? FileManager.default.createDirectory(at: playlists.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(playlists.folder)
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Ustaw MusicLite jako domyślny odtwarzacz muzyki") { Task { await DefaultApp.claimFromMenu() } }
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
            alert("MusicLite już otwiera wszystkie formaty muzyki.", "Formaty: \(types.count).")
            return
        }
        let ask = NSAlert()
        ask.messageText = "Ustawić MusicLite jako domyślny? Formaty do zmiany: \(todo.count)."
        ask.informativeText = """
            macOS może zapytać o każdy z nich w osobnym okienku — kliknij w nim „Używaj MusicLite”. \
            Formaty, które MusicLite już otwiera, pomijam.

            \(todo.map { $0.preferredFilenameExtension ?? $0.identifier }.joined(separator: ", "))
            """
        ask.addButton(withTitle: "Ustaw")
        ask.addButton(withTitle: "Anuluj")
        guard ask.runModal() == .alertFirstButtonReturn else { return }

        isClaiming = true
        defer { isClaiming = false }
        let failed = await claim(todo)
        alert(failed.isEmpty
              ? "Gotowe. Zmienione formaty: \(todo.count)."
              : "Nie udało się dla \(failed.count) z \(todo.count) formatów.",
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
