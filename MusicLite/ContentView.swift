import SwiftUI

struct ContentView: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var playlists = Playlists.shared
    @ObservedObject var eq = Equalizer.shared
    @AppStorage("showList") private var showList = false
    @State private var showEQ = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                VStack(spacing: 10) {
                    status
                    controls
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if showList {
                Divider()
                songList
            }
        }
        .frame(width: 460)
        .navigationTitle(title)
        .dropDestination(for: URL.self) { urls, _ in
            // Files only: a link dragged from a browser would be streamed from the web.
            // Dropped songs join the list, so one can be built from several folders.
            let files = urls.filter(\.isFileURL)
            player.add(files)
            return !files.isEmpty
        }
    }

    @ViewBuilder private var status: some View {
        switch player.state {
        case .empty:
            Text("Drop a music file here or open one (⌘O)")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 22)
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if !player.loadingNote.isEmpty {
                    Text(player.loadingNote).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 22)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 22)
        case .ready:
            HStack(spacing: 8) {
                Text(time(player.position)).frame(width: 52, alignment: .trailing)
                Slider(value: $player.position, in: 0...max(player.duration, 0.1)) { editing in
                    if editing { player.isScrubbing = true } else { player.seek() }
                }
                Text(time(player.duration)).frame(width: 52, alignment: .leading)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: player.queue.count > 1 ? 16 : 22) {
            if player.queue.count > 1 {
                button("shuffle", player.shuffle ? "Shuffle: on" : "Shuffle: off") { player.shuffle.toggle() }
                    .foregroundStyle(player.shuffle ? Color.accentColor : .secondary)
                button("backward.end.fill", "Previous") { player.previous() }
                    .disabled(!player.hasPrevious)
            }
            button("gobackward.10", "Skip back 10 s") { player.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            button(player.isPlaying ? "pause.fill" : "play.fill", player.isPlaying ? "Pause" : "Play", size: 26) {
                player.togglePlay()
            }
            .keyboardShortcut(.space, modifiers: [])
            .frame(width: 34)
            button("goforward.10", "Skip forward 10 s") { player.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            if player.queue.count > 1 {
                button("forward.end.fill", "Next") { player.next() }
                    .disabled(!player.hasNext)
            }
            button(player.repeatMode == .one ? "repeat.1" : "repeat", repeatHelp) {
                player.repeatMode = switch player.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
            }
            .foregroundStyle(player.repeatMode == .off ? Color.secondary : .accentColor)
        }
        .disabled(player.state != .ready)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            button("slider.vertical.3", "Equalizer and balance (⌥⌘E)") { showEQ.toggle() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .foregroundStyle(eq.isOn || eq.balance != 0 ? Color.accentColor : .primary)
                .popover(isPresented: $showEQ, arrowEdge: .bottom) { EqualizerView() }
        }
        .overlay(alignment: .trailing) {
            button(showList ? "chevron.up" : "list.bullet", showList ? "Hide list" : "Song list (⌘L)") {
                showList.toggle()
            }
            .keyboardShortcut("l")
        }
    }

    private var songList: some View {
        VStack(spacing: 0) {
            listBar
            Divider()
            songRows
        }
    }

    private var listBar: some View {
        HStack(spacing: 12) {
            // The name is the playlist menu: saved playlists to switch to, save, delete.
            Menu {
                ForEach(playlists.names, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { player.playlistName == name }, set: { _ in playlists.open(name) }))
                }
                if playlists.names.isEmpty {
                    Text("No Saved Playlists")
                }
                Divider()
                Button("Save List as Playlist…") { playlists.saveCurrent() }
                    .disabled(player.queue.isEmpty)
                if !playlists.names.isEmpty {
                    Menu("Delete Playlist") {
                        ForEach(playlists.names, id: \.self) { name in
                            Button(name) { playlists.delete(name) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(player.playlistName ?? String(localized: "Current List"))
                        .fontWeight(player.playlistName == nil ? .regular : .semibold)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playlists")
            Text("\(player.queue.count)").foregroundStyle(.tertiary)
            Spacer()
            button("plus", "Add songs or folders (⇧⌘O)") {
                if let urls = MusicLiteApp.pick(title: String(localized: "Add to List")) { player.add(urls) }
            }
            button("trash", "Clear list") { player.clear() }
                .disabled(player.queue.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 30)
    }

    private var songRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.queue.enumerated()), id: \.offset) { row, url in
                        Button { player.play(at: row) } label: {
                            HStack(spacing: 8) {
                                Group {
                                    if row == player.index {
                                        Image(systemName: "speaker.wave.2.fill").font(.caption)
                                    } else {
                                        Text("\(row + 1)")
                                            .font(.callout.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: numberWidth, alignment: .trailing)
                                Text(url.deletingPathExtension().lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(url.pathExtension.uppercased())
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                            .background(row == player.index ? Color.accentColor.opacity(0.18) : .clear)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Play") { player.play(at: row) }
                            Button("Move Up") { player.move(row, by: -1) }
                                .disabled(row == 0)
                            Button("Move Down") { player.move(row, by: 1) }
                                .disabled(row + 1 >= player.queue.count)
                            Divider()
                            Button("Remove from List") { player.remove(at: row) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        .help(url.path)
                        .id(row)
                    }
                }
                .padding(.vertical, 4)
            }
            // Opens at up to ten rows; the window can then be dragged taller (or back down to
            // four rows) — .windowResizability(.contentSize) takes its limits from this frame.
            .frame(minHeight: listMinHeight, idealHeight: listIdealHeight, maxHeight: .infinity)
            .overlay {
                if player.queue.isEmpty {
                    Text("The list is empty — drop songs or folders here").foregroundStyle(.secondary)
                }
            }
            .onAppear { proxy.scrollTo(player.index, anchor: .center) }
            .onChange(of: player.index) { _, row in
                withAnimation { proxy.scrollTo(row, anchor: .center) }
            }
        }
    }

    private var listIdealHeight: CGFloat {
        player.queue.isEmpty ? 40 : min(CGFloat(player.queue.count) * 24 + 8, 248)
    }

    private var listMinHeight: CGFloat {
        min(listIdealHeight, 4 * 24 + 8)
    }

    /// Wide enough for the longest number on the list.
    private var numberWidth: CGFloat {
        CGFloat(String(player.queue.count).count) * 8 + 6
    }

    private var repeatHelp: LocalizedStringKey {
        switch player.repeatMode {
        case .off: "Repeat: off"
        case .all: "Repeat: all songs"
        case .one: "Repeat: one song"
        }
    }

    private var title: String {
        guard !player.title.isEmpty else { return "MusicLite" }
        guard player.queue.count > 1 else { return player.title }
        return "\(player.title)  (\(player.index + 1)/\(player.queue.count))"
    }

    private func button(_ symbol: String, _ help: LocalizedStringKey, size: CGFloat = 17, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size))
        }
        .buttonStyle(.borderless)
        .help(help)
        // Without it VoiceOver reads the symbol's own (English) name.
        .accessibilityLabel(help)
    }

    private func time(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
