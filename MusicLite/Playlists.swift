import AppKit

/// Saved playlists: one M3U8 file each (full paths, one per line) in
/// ~/Library/Application Support/MusicLite/Playlisty. The file name is the playlist name.
@MainActor
final class Playlists: ObservableObject {
    static let shared = Playlists()

    @Published private(set) var names: [String] = []

    let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MusicLite/Playlisty", isDirectory: true)

    private init() { reload() }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        names = files.filter { $0.pathExtension == "m3u8" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func file(_ name: String) -> URL {
        folder.appendingPathComponent(name).appendingPathExtension("m3u8")
    }

    func save(_ songs: [URL], as name: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = (["#EXTM3U"] + songs.map(\.path)).joined(separator: "\n") + "\n"
        try text.write(to: file(name), atomically: true, encoding: .utf8)
        reload()
    }

    /// The songs still on disk and how many of the saved ones are gone.
    func songs(_ name: String) -> (found: [URL], missing: Int) {
        let text = (try? String(contentsOf: file(name), encoding: .utf8)) ?? ""
        let paths = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        let found = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        return (found, paths.count - found.count)
    }

    func open(_ name: String) {
        let (found, missing) = songs(name)
        if missing > 0 {
            alert("Brakuje plików: \(missing) z \(found.count + missing).",
                  "Zostały przeniesione albo usunięte. Gram resztę; zapisz playlistę, żeby o nich zapomniała.")
        }
        if found.isEmpty { return }
        Player.shared.open(found, playlist: name)
    }

    /// Asks for a name (the current playlist's by default) and saves the window's list.
    func saveCurrent() {
        let player = Player.shared
        guard !player.queue.isEmpty else { return }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = player.playlistName ?? ""
        field.placeholderString = "Nazwa playlisty"
        let ask = NSAlert()
        ask.messageText = "Zapisz listę jako playlistę"
        ask.informativeText = "Utwory: \(player.queue.count)."
        ask.accessoryView = field
        ask.addButton(withTitle: "Zapisz")
        ask.addButton(withTitle: "Anuluj")
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        // "/" and ":" cannot stand in a file name; a leading dot would hide the file.
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return }
        if names.contains(name), name != player.playlistName,
           !confirm("Playlista „\(name)” już jest. Zastąpić ją?", "Zastąp") { return }
        do {
            try save(player.queue, as: name)
            player.playlistName = name
        } catch {
            alert("Nie udało się zapisać playlisty.", error.localizedDescription)
        }
    }

    func delete(_ name: String) {
        guard confirm("Usunąć playlistę „\(name)”?", "Usuń", details: "Utwory zostają na dysku — znika tylko lista.") else { return }
        try? FileManager.default.trashItem(at: file(name), resultingItemURL: nil)
        if Player.shared.playlistName == name { Player.shared.playlistName = nil }
        reload()
    }

    private func confirm(_ message: String, _ button: String, details: String = "") -> Bool {
        let ask = NSAlert()
        ask.messageText = message
        ask.informativeText = details
        ask.addButton(withTitle: button)
        ask.addButton(withTitle: "Anuluj")
        return ask.runModal() == .alertFirstButtonReturn
    }

    private func alert(_ message: String, _ details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }
}
