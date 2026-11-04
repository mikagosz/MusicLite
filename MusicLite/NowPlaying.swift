import AppKit
import AVFoundation
import MediaPlayer

/// The "Now Playing" tile in Control Center and the media keys (F7–F9, headphone buttons).
/// macOS hands both to the app that last set `nowPlayingInfo` and answers the remote commands.
@MainActor
final class NowPlaying {
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private var artwork: MPMediaItemArtwork?

    init(_ player: Player) {
        // The handlers may come on any queue, so each one hops to the main actor.
        handle(player, commands.playCommand) { if !$0.isPlaying { $0.togglePlay() } }
        handle(player, commands.pauseCommand) { if $0.isPlaying { $0.togglePlay() } }
        handle(player, commands.togglePlayPauseCommand) { $0.togglePlay() }
        handle(player, commands.nextTrackCommand) { $0.next() }
        // Like every player: past the first seconds "previous" rewinds the song.
        handle(player, commands.previousTrackCommand) {
            if $0.position > 3 || !$0.hasPrevious { $0.skip(-$0.position) } else { $0.previous() }
        }
        commands.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in player.map { $0.skip(time - $0.position) } }
            return .success
        }
    }

    private func handle(_ player: Player, _ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
        command.addTarget { [weak player] _ in
            Task { @MainActor in player.map(action) }
            return .success
        }
    }

    /// A new song started loading: title right away, artwork once the file tells us.
    func loading(_ title: String, from url: URL) {
        artwork = nil
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: title]
        center.playbackState = .paused
        Task { [weak self] in
            guard let image = await Self.cover(of: url), let self,
                  self.center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == title else { return }
            self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            self.center.nowPlayingInfo?[MPMediaItemPropertyArtwork] = self.artwork
        }
    }

    /// Called whenever playing, position or length change; macOS moves the clock on its own between calls.
    func update(title: String, duration: Double, position: Double, isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    func clear() {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// The cover embedded in the file (ID3, MP4, FLAC picture), nil when it has none.
    private static func cover(of url: URL) async -> NSImage? {
        guard let items = try? await AVURLAsset(url: url).load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let image = NSImage(data: data) { return image }
        }
        return nil
    }
}
