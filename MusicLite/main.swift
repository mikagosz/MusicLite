import AppKit

// `MusicLite --probe <file>` loads a file the way the window does, without playing it, and prints
// the engine and length; `MusicLite --list <file or folder>…` prints the song list opening those
// builds, with "> " before the song it starts at.
// `MusicLite --probe-eq <file>` plays it muted through the equalizer's tap and prints the level of
// the left channel three times: flat, with 1 kHz cut by 12 dB, and with the balance fully right.
// `MusicLite --probe-switch <slow file> <file>` opens both muted, switches to the second while the
// first is still loading and prints what the second loaded as. Tests/check.sh uses all three.
// `MusicLite --set-default` does what the menu item "Make MusicLite the Default Music Player" does,
// for the formats MusicLite does not open yet.
let args = CommandLine.arguments
if args.count >= 3, args[1] == "--probe" {
    Task { @MainActor in
        let player = Player.shared
        await player.load(URL(fileURLWithPath: args[2]), autoplay: false)
        if case .failed(let message) = player.state {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
        print(player.engine, String(format: "%.2f", player.duration))
        player.cleanUp()
        exit(0)
    }
    RunLoop.main.run()
}
if args.count >= 4, args[1] == "--probe-switch" {
    Task { @MainActor in
        let player = Player.shared
        player.isMuted = true
        player.open([URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3])])
        try? await Task.sleep(for: .milliseconds(500))
        player.play(at: 1)
        await player.waitForLoad()
        print(player.engine, player.title, String(format: "%.2f", player.duration))
        player.stop()
        exit(player.state == .ready ? 0 : 1)
    }
    RunLoop.main.run()
}
if args.count >= 3, args[1] == "--probe-eq" {
    Task { @MainActor in
        let player = Player.shared
        let audio = Equalizer.shared.audio
        player.isMuted = true
        await player.load(URL(fileURLWithPath: args[2]), autoplay: false)
        guard player.state == .ready else { exit(1) }
        player.togglePlay()
        // Straight to the tap, not through Equalizer: the probe must not change saved settings.
        var levels: [Float] = []
        for (gains, balance) in [([Float](repeating: 0, count: 10), Float(0)),
                                 ([0, 0, 0, 0, 0, -12, 0, 0, 0, 0], 0),
                                 ([Float](repeating: 0, count: 10), 1)] {
            audio.set(isOn: true, gains: gains, preamp: 0, balance: balance)
            try? await Task.sleep(for: .milliseconds(700))
            levels.append(audio.level.withLock { $0 })
        }
        print(levels.map { String(format: "%.4f", $0) }.joined(separator: " "))
        player.stop()
        exit(0)
    }
    RunLoop.main.run()
}
if args.count >= 3, args[1] == "--list" {
    MainActor.assumeIsolated {
        let (songs, index) = Player.queue(for: args.dropFirst(2).map { URL(fileURLWithPath: $0) })
        for (row, song) in songs.enumerated() { print((row == index ? "> " : "") + song.lastPathComponent) }
    }
    exit(0)
}
if args.count >= 2, args[1] == "--set-default" {
    Task { @MainActor in
        let todo = DefaultApp.missing
        let failed = await DefaultApp.claim(todo)
        print(String(localized: "Formats: \(DefaultApp.types.count), to change: \(todo.count), errors: \(failed.count)"))
        failed.forEach { print("  \($0)") }
        exit(failed.isEmpty ? 0 : 1)
    }
    RunLoop.main.run()
}

MusicLiteApp.main()
