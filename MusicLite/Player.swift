import AVFoundation
import Combine

/// One AVPlayer for the whole app. Files AVFoundation cannot play go through FFmpeg.decode
/// first. The queue (the window's song list) plays one after another. Every item goes
/// through the equalizer's tap (Equalizer.swift).
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum State: Equatable {
        case empty, loading, ready
        case failed(String)
    }

    @Published private(set) var state = State.empty
    @Published private(set) var title = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var duration = 0.0
    /// Shown next to the spinner while loading takes long: ffmpeg decodes the whole file first.
    @Published private(set) var loadingNote = ""
    /// Seconds. The slider writes it while dragging; `seek()` applies it on release.
    @Published var position = 0.0
    /// "avfoundation" or "ffmpeg" — shown nowhere, read by `MusicLite --probe`.
    private(set) var engine = ""
    @Published private(set) var queue: [URL] = []
    @Published private(set) var index = 0
    /// The saved playlist the list came from; nil once the list holds anything else.
    @Published var playlistName: String?

    enum Repeat: String { case off, all, one }
    @Published var shuffle = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet {
            UserDefaults.standard.set(shuffle, forKey: "shuffle")
            reshuffle()
        }
    }
    @Published var repeatMode = Repeat(rawValue: UserDefaults.standard.string(forKey: "repeat") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeat") }
    }
    /// Shuffle: rows not played yet this round, in the order they will come.
    private var upcoming: [Int] = []
    /// Shuffle: rows played before the current one, so "previous" goes back the same way.
    private var history: [Int] = []
    var isScrubbing = false
    /// Silences the player; `MusicLite --probe-switch` uses it, the window never does.
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    private let player = AVPlayer()
    private var decoded: URL?
    private var loadID = UUID()
    /// The load started from the window. A newer one cancels it, which also stops its ffmpeg.
    private var loading: Task<Void, Never>?
    /// Control Center and the media keys. Made by the first load from the window, so the
    /// `--probe` runs never show up there.
    private var nowPlaying: NowPlaying?

    private init() {
        FFmpeg.removeTemporaryFiles()
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing, time.seconds.isFinite else { return }
                self.position = time.seconds
            }
        }
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                if self.repeatMode == .one {
                    self.player.seek(to: .zero)
                    self.position = 0
                    self.player.play()
                    self.publish()
                } else if let row = self.rowAfter() {
                    self.play(at: row)
                } else {
                    self.finish()
                }
            }
        }
    }

    /// Replaces the list with `urls` (a folder brings its songs) and plays the first.
    func open(_ urls: [URL], playlist: String? = nil) {
        let (songs, row) = Self.queue(for: urls)
        guard !songs.isEmpty else { return }
        (queue, index) = (songs, row)
        playlistName = playlist
        reshuffle()
        startLoading(queue[index])
    }

    /// The list opening `urls` builds and the row it starts at: just those files, in the
    /// order given — one file is a list of one, its folder stays out. A folder adds its songs.
    static func queue(for urls: [URL]) -> (songs: [URL], index: Int) {
        (expand(urls), 0)
    }

    /// Files resolved (a symlink plays the song it points to), folders replaced by their songs.
    static func expand(_ urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
                return songs(in: url)
            }
            return [url.resolvingSymlinksInPath()]
        }
    }

    /// Adds to the end of the list; plays the first added song when nothing was loaded.
    func add(_ urls: [URL]) {
        let songs = Self.expand(urls)
        guard !songs.isEmpty else { return }
        let first = queue.count
        queue += songs
        upcoming += first..<queue.count
        upcoming.shuffle()
        switch state {
        case .empty, .failed: play(at: first)
        case .loading, .ready: break
        }
    }

    func remove(at row: Int) {
        guard queue.indices.contains(row) else { return }
        queue.remove(at: row)
        renumber { $0 == row ? nil : $0 > row ? $0 - 1 : $0 }
        if row < index {
            index -= 1
        } else if row == index {
            if queue.isEmpty { clear() } else {
                index = min(row, queue.count - 1)
                upcoming.removeAll { $0 == index }
                startLoading(queue[index], autoplay: isPlaying)
            }
        }
    }

    /// Swaps a row with its neighbour (`delta` -1 up, +1 down); the playing song stays marked.
    func move(_ row: Int, by delta: Int) {
        let other = row + delta
        guard queue.indices.contains(row), queue.indices.contains(other) else { return }
        queue.swapAt(row, other)
        renumber { $0 == row ? other : $0 == other ? row : $0 }
        if index == row { index = other } else if index == other { index = row }
    }

    /// Empties the list and stops: the window goes back to "drop a file here".
    func clear() {
        loading?.cancel()
        loading = nil
        loadID = UUID()
        player.pause()
        cleanUp()
        (queue, index, playlistName, upcoming, history) = ([], 0, nil, [], [])
        (title, isPlaying, position, duration, loadingNote) = ("", false, 0, 0, "")
        state = .empty
        nowPlaying?.clear()
    }

    func play(at row: Int) {
        guard queue.indices.contains(row) else { return }
        if shuffle, state != .empty, row != index {
            history.append(index)
            upcoming.removeAll { $0 == row }
        }
        index = row
        startLoading(queue[row])
    }

    private func startLoading(_ url: URL, autoplay: Bool = true) {
        loading?.cancel()
        if nowPlaying == nil, !isMuted { nowPlaying = NowPlaying(self) }
        loading = Task { await load(url, autoplay: autoplay) }
    }

    /// Waits for the load started from the window (or by `open`/`play(at:)`).
    func waitForLoad() async {
        await loading?.value
    }

    /// The songs straight in `folder` (no subfolders, videos or hidden files), in Finder's name order.
    static func songs(in folder: URL) -> [URL] {
        let audio = Set(DefaultApp.extensions).subtracting(["wmv", "asf"])
        let all = (try? FileManager.default.contentsOfDirectory(
            at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return all.map { $0.resolvingSymlinksInPath() }
            .filter { audio.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// The row "next" goes to: the following one, a random unplayed one when shuffling,
    /// and with repeat on the list starts over instead of ending.
    private func rowAfter() -> Int? {
        if shuffle {
            if upcoming.isEmpty, repeatMode != .off, queue.count > 1 {
                upcoming = queue.indices.filter { $0 != index }.shuffled()
            }
            return upcoming.first
        }
        if index + 1 < queue.count { return index + 1 }
        return repeatMode != .off && queue.count > 1 ? 0 : nil
    }

    var hasNext: Bool {
        let wraps = repeatMode != .off && queue.count > 1
        return shuffle ? !upcoming.isEmpty || wraps : index + 1 < queue.count || wraps
    }

    var hasPrevious: Bool {
        shuffle ? !history.isEmpty : index > 0 || repeatMode != .off && queue.count > 1
    }

    func next() {
        if let row = rowAfter() { play(at: row) }
    }

    func previous() {
        if shuffle {
            guard let row = history.popLast() else { return }
            upcoming.insert(index, at: 0)
            index = row
            startLoading(queue[row])
        } else if hasPrevious {
            index = index > 0 ? index - 1 : queue.count - 1
            startLoading(queue[index])
        }
    }

    /// A new shuffle round: every other row once, in random order; nothing to go back to.
    private func reshuffle() {
        upcoming = shuffle ? queue.indices.filter { $0 != index }.shuffled() : []
        history = []
    }

    /// Keeps the shuffle rows pointing at the same songs after the list changed; nil drops a row.
    private func renumber(_ change: (Int) -> Int?) {
        upcoming = upcoming.compactMap(change)
        history = history.compactMap(change)
    }

    func togglePlay() {
        guard state == .ready else { return }
        if isPlaying { player.pause() } else {
            if position >= duration - 0.1 { player.seek(to: .zero); position = 0 }
            player.play()
        }
        isPlaying.toggle()
        publish()
    }

    func skip(_ seconds: Double) {
        guard state == .ready else { return }
        // Like dragging the slider: the clock must not overwrite the new position before
        // the seek lands; seek() clears the flag when it does.
        isScrubbing = true
        position = min(max(position + seconds, 0), duration)
        seek()
    }

    func seek() {
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isScrubbing = false
                self?.publish()
            }
        }
    }

    func cleanUp() {
        player.replaceCurrentItem(with: nil)
        if let decoded { try? FileManager.default.removeItem(at: decoded) }
        decoded = nil
    }

    /// The app is quitting: stop ffmpeg and remove every temporary file of this process,
    /// including one ffmpeg is still writing.
    func stop() {
        loading?.cancel()
        cleanUp()
        nowPlaying?.clear()
        FFmpeg.removeTemporaryFiles(includingOwn: true)
    }

    func load(_ url: URL, autoplay: Bool) async {
        let id = UUID()
        loadID = id
        player.pause()
        isPlaying = false
        cleanUp()
        title = url.deletingPathExtension().lastPathComponent
        nowPlaying?.loading(title, from: url)
        position = 0
        duration = 0
        loadingNote = ""
        state = .loading

        engine = "avfoundation"
        if let length = await start(AVURLAsset(url: url), id), loadID == id {
            return ready(length, autoplay: autoplay)
        }
        guard loadID == id, !Task.isCancelled else { return }
        engine = "ffmpeg"
        loadingNote = "Dekoduję przez ffmpeg…"
        do {
            let file = try await FFmpeg.decode(url)
            // Another file was opened while ffmpeg worked: this one is no longer wanted.
            guard loadID == id else { try? FileManager.default.removeItem(at: file); return }
            decoded = file
            if let length = await start(AVURLAsset(url: file), id), loadID == id {
                return ready(length, autoplay: autoplay)
            }
            if loadID == id { cleanUp(); nowPlaying?.clear(); state = .failed("Nie umiem odtworzyć tego pliku.") }
        } catch {
            if loadID == id, !(error is CancellationError) { nowPlaying?.clear(); state = .failed(error.localizedDescription) }
        }
    }

    /// Duration once the item is ready, nil when AVFoundation cannot really play it.
    /// Ogg Vorbis comes back "ready" with a zero length, so that counts as a failure too.
    /// Every step checks `id`: a newer load may have put its own item in the player meanwhile.
    private func start(_ asset: AVURLAsset, _ id: UUID) async -> Double? {
        guard (try? await asset.load(.isPlayable)) == true,
              let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
              loadID == id, !Task.isCancelled else { return nil }
        let item = AVPlayerItem(asset: asset)
        item.audioMix = Equalizer.shared.audio.mix(for: tracks[0])
        player.replaceCurrentItem(with: item)
        if await settled(item) == .readyToPlay, item.duration.seconds.isFinite, item.duration.seconds > 0 {
            return item.duration.seconds
        }
        if player.currentItem === item { player.replaceCurrentItem(with: nil) }
        return nil
    }

    /// The item's first status other than `.unknown`; `.unknown` when the load is cancelled,
    /// since an item taken out of the player before it got ready may never settle.
    private func settled(_ item: AVPlayerItem) async -> AVPlayerItem.Status {
        let wait = Settle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                wait.start(item, continuation)
            }
        } onCancel: {
            DispatchQueue.main.async { wait.finish(.unknown) }
        }
    }

    private func ready(_ length: Double, autoplay: Bool) {
        duration = length
        state = .ready
        if autoplay {
            player.play()
            isPlaying = true
        }
        publish()
    }

    private func finish() {
        isPlaying = false
        position = duration
        publish()
    }

    private func publish() {
        nowPlaying?.update(title: title, duration: duration, position: position, isPlaying: isPlaying)
    }
}

/// Resumes the continuation once, with the first settled status. KVO, not
/// `publisher(for: \.status).values`: that one hung forever in `--probe`.
/// Its state is only touched on the main queue, hence `@unchecked Sendable`.
private final class Settle: @unchecked Sendable {
    private var continuation: CheckedContinuation<AVPlayerItem.Status, Never>?
    private var watch: NSKeyValueObservation?

    func start(_ item: AVPlayerItem, _ continuation: CheckedContinuation<AVPlayerItem.Status, Never>) {
        self.continuation = continuation
        watch = item.observe(\.status, options: [.initial, .new]) { [self] item, _ in
            let status = item.status
            DispatchQueue.main.async {
                if status != .unknown { self.finish(status) }
            }
        }
    }

    func finish(_ status: AVPlayerItem.Status) {
        watch?.invalidate()
        watch = nil
        continuation?.resume(returning: status)
        continuation = nil
    }
}
