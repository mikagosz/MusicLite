import Foundation

// Headless check of UpdateSupport.swift, compiled together with it by Tests/check.sh:
//   swiftc Tests/updates.swift MusicLite/UpdateSupport.swift
// Prints one "ok"/"FAIL" line per check and exits 1 on any failure.

var failed = false
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  ok   \(what)" : "  FAIL \(what)")
    if !ok { failed = true }
}

// Addresses from the update file: only https on our download server, no login in the address.
check(DownloadAddress.allowed(URL(string: "https://downloads.fractal8.eu/MusicLite/MusicLite%200.1.22.zip")!), "https na downloads.fractal8.eu przechodzi")
for bad in ["http://downloads.fractal8.eu/x.zip", "https://example.com/x.zip", "file:///Applications/Calculator.app",
            "smb://192.168.1.1/x", "https://user:pass@downloads.fractal8.eu/x.zip", "https://downloads.fractal8.eu.example.com/x.zip"] {
    check(!DownloadAddress.allowed(URL(string: bad)!), "odrzucony adres \(bad)")
}

// The version is read from the Info.plist on disk.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MusicLiteUpdatesTest-\(getpid())")
defer { try? FileManager.default.removeItem(at: dir) }
let app = dir.appendingPathComponent("Fake.app")
try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "9.8.7"], format: .xml, options: 0)
try! plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
check(RestartAfterUpdate.versionOnDisk(app) == "9.8.7", "wersja z Info.plist na dysku")
check(RestartAfterUpdate.versionOnDisk(dir.appendingPathComponent("Missing.app")) == nil, "brak programu daje nil")
check(RestartAfterUpdate.writablePlace(app), "folder do zapisu jest miejscem do podmiany")
check(!RestartAfterUpdate.writablePlace(dir), "katalog bez .app nie jest programem")

// The restart helper waits for the old process to end: the marker must not appear before it does.
let sleeper = Process()
sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
sleeper.arguments = ["1"]
try! sleeper.run()
let marker = dir.appendingPathComponent("opened")
try! RestartAfterUpdate.launchAfterExit(pid: sleeper.processIdentifier, app: marker, opener: "/usr/bin/touch")
Thread.sleep(forTimeInterval: 0.4)
check(!FileManager.default.fileExists(atPath: marker.path), "pomocnik czeka, dopóki stary proces żyje")
sleeper.waitUntilExit()
var appeared = false
for _ in 0..<20 where !appeared {
    Thread.sleep(forTimeInterval: 0.2)
    appeared = FileManager.default.fileExists(atPath: marker.path)
}
check(appeared, "pomocnik otwiera nową wersję po końcu procesu")

exit(failed ? 1 : 0)
