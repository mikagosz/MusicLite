import AVFoundation
import os

/// Ten-band equalizer and left/right balance. The settings live here (saved in UserDefaults);
/// the sound goes through `EQAudio`, a processing tap on every AVPlayerItem.
@MainActor
final class Equalizer: ObservableObject {
    static let shared = Equalizer()

    static let bands = EQAudio.bands
    static let range: ClosedRange<Float> = -12...12
    static let flat = "Korekcja zerowa"
    static let custom = "Własne"

    /// What the menu shows: the names below are also what gets saved (`eqPreset`), so they stay
    /// as they were and Localizable.xcstrings gives them Apple Music's English names.
    static func displayName(_ name: String) -> String {
        Bundle.main.localizedString(forKey: name, value: name, table: nil)
    }

    /// Apple Music's presets, names as its Polish version shows them. Values in dB, read from
    /// ~/Library/Preferences/com.apple.Music.eq.plist (2026-10-27), all with the preamp at 0.
    static let presets: [(name: String, gains: [Float])] = [
        ("Akustyczna", [5, 4.9, 3.95, 1.05, 2.15, 1.75, 3.5, 4.1, 3.55, 2.15]),
        ("Dance", [3.57, 6.55, 4.99, 0, 1.92, 3.65, 5.15, 4.54, 3.59, 0]),
        ("Elektroniczna", [4.25, 3.8, 1.2, 0, -2.15, 2.25, 0.85, 1.25, 3.95, 4.8]),
        ("Głębia", [4.95, 3.55, 1.75, 1, 2.85, 2.5, 1.45, -2.15, -3.55, -4.6]),
        ("Głośność", [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        ("Hip-Hop", [5, 4.25, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        ("Jazz", [4, 3, 1.5, 2.25, -1.5, -1.5, 0, 1.5, 3, 3.75]),
        ("Klasyczna", [4.75, 3.75, 3, 2.5, -1.5, -1.5, 0, 2.25, 3.25, 3.75]),
        (flat, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Latynoska", [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        ("Lounge", [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
        ("Małe głośniki", [5.5, 4.25, 3.5, 2.5, 1.25, 0, -1.25, -2.5, -3.5, -4.25]),
        ("Mniej basów", [-5.5, -4.25, -3.5, -2.5, -1.25, 0, 0, 0, 0, 0]),
        ("Mniej wysokich tonów", [0, 0, 0, 0, 0, -1.25, -2.5, -3.5, -4.25, -5.5]),
        ("Pianino", [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        ("Pop", [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        ("R&B", [2.62, 6.92, 5.65, 1.33, -2.19, -1.5, 2.32, 2.65, 3, 3.75]),
        ("Recytacje", [-3.46, -0.47, 0, 0.69, 3.46, 4.61, 4.84, 4.28, 2.54, 0]),
        ("Rock", [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5]),
        ("Więcej basów", [5.5, 4.25, 3.5, 2.5, 1.25, 0, 0, 0, 0, 0]),
        ("Więcej wokali", [-1.5, -3, -3, 1.5, 3.75, 3.75, 3, 1.5, 0, -1.5]),
        ("Więcej wysokich tonów", [0, 0, 0, 0, 0, 1.25, 2.5, 3.5, 4.25, 5.5]),
    ]

    @Published var isOn: Bool { didSet { save() } }
    @Published private(set) var gains: [Float] { didSet { save() } }
    /// Whole-signal gain in dB before the bands, to make room for boosts.
    @Published var preamp: Float { didSet { save() } }
    /// -1 only left, 0 middle, 1 only right. Works with the equalizer off too.
    @Published var balance: Float { didSet { save() } }
    /// A name from `presets`, or `custom` once a band was moved by hand.
    @Published private(set) var preset: String { didSet { save() } }

    let audio = EQAudio()
    private let defaults = UserDefaults.standard

    private init() {
        isOn = defaults.bool(forKey: "eqOn")
        gains = (defaults.array(forKey: "eqGains") as? [Float]).flatMap { $0.count == 10 ? $0 : nil }
            ?? Array(repeating: 0, count: 10)
        preamp = defaults.float(forKey: "eqPreamp")
        balance = defaults.float(forKey: "balance")
        preset = defaults.string(forKey: "eqPreset") ?? Self.flat
        audio.set(isOn: isOn, gains: gains, preamp: preamp, balance: balance)
    }

    func choose(_ name: String) {
        guard let found = Self.presets.first(where: { $0.name == name }) else { return }
        gains = found.gains
        preset = name
        isOn = true
    }

    func setGain(_ band: Int, _ value: Float) {
        gains[band] = value
        preset = Self.presets.first { $0.gains == gains }?.name ?? Self.custom
    }

    func reset() {
        choose(Self.flat)
        preamp = 0
        balance = 0
    }

    private func save() {
        defaults.set(isOn, forKey: "eqOn")
        defaults.set(gains, forKey: "eqGains")
        defaults.set(preamp, forKey: "eqPreamp")
        defaults.set(balance, forKey: "balance")
        defaults.set(preset, forKey: "eqPreset")
        audio.set(isOn: isOn, gains: gains, preamp: preamp, balance: balance)
    }
}

/// What the audio thread reads. The main thread writes it; each tap picks up a change
/// on its next buffer and recomputes its filters.
final class EQAudio: @unchecked Sendable {
    /// Band centres in Hz, the same ten as in Apple's Music app.
    static let bands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    struct Values {
        var isOn = false
        var gains = [Float](repeating: 0, count: 10)
        var preamp: Float = 0
        var balance: Float = 0
        var version = 0
    }

    private let values = OSAllocatedUnfairLock(initialState: Values())
    /// RMS of the first channel in the last processed buffer; `MusicLite --probe-eq` prints it.
    let level = OSAllocatedUnfairLock<Float>(initialState: 0)

    func set(isOn: Bool, gains: [Float], preamp: Float, balance: Float) {
        values.withLock { $0 = Values(isOn: isOn, gains: gains, preamp: preamp, balance: balance, version: $0.version + 1) }
    }

    var current: Values { values.withLock { $0 } }

    /// An audio mix that sends `track` through a new tap. nil if the tap cannot be made:
    /// the song then plays as it is.
    func mix(for track: AVAssetTrack) -> AVAudioMix? {
        let context = Unmanaged.passRetained(TapContext(self))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, clientInfo, storage in storage.pointee = clientInfo },
            finalize: { tap in Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, format in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap else {
            context.release()
            return nil
        }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }
}

/// One tap's filters. Only the audio thread touches it after `prepare`.
private final class TapContext {
    /// RBJ peaking filter in transposed direct form II; Double, because at 32 Hz Float drifts.
    struct Band {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

        init(frequency: Double, gain: Double, sampleRate: Double) {
            let a = pow(10, gain / 40)
            let w = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w) / (2 * 1.41)  // Q 1.41: one octave wide, like the band spacing
            let a0 = 1 + alpha / a
            b0 = (1 + alpha * a) / a0
            b1 = -2 * cos(w) / a0
            b2 = (1 - alpha * a) / a0
            a1 = b1
            a2 = (1 - alpha / a) / a0
        }
    }

    let shared: EQAudio
    private var sampleRate = 44100.0
    private var isFloat = false
    private var version = -1
    private var bands: [Band] = []
    /// z1, z2 per channel per band.
    private var memory: [Double] = []
    private var preamp = 1.0
    private var left = 1.0, right = 1.0

    init(_ shared: EQAudio) { self.shared = shared }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        // AVPlayer hands taps 32-bit float; anything else passes through untouched.
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        memory = Array(repeating: 0, count: Int(format.mChannelsPerFrame) * 10 * 2)
        version = -1
    }

    private func update(_ values: EQAudio.Values) {
        version = values.version
        bands = values.isOn
            ? zip(EQAudio.bands, values.gains).compactMap { frequency, gain in
                // A band at 0 dB does nothing; one too close to Nyquist would be unstable.
                gain == 0 || frequency >= sampleRate * 0.45 ? nil
                    : Band(frequency: frequency, gain: Double(gain), sampleRate: sampleRate)
            }
            : []
        preamp = values.isOn ? pow(10, Double(values.preamp) / 20) : 1
        left = Double(min(1, 1 - values.balance))
        right = Double(min(1, 1 + values.balance))
        memory = Array(repeating: 0, count: memory.count)
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat else { return }
        let values = shared.current
        if values.version != version { update(values) }
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        var channel = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let stride = Int(buffer.mNumberChannels)
            for inBuffer in 0..<stride {
                let gain = preamp * (channels == 2 ? (channel == 0 ? left : right) : 1)
                let base = channel * 10 * 2
                guard base + bands.count * 2 <= memory.count else { break }
                if bands.isEmpty, gain == 1 { channel += 1; continue }
                for frame in 0..<frames {
                    let i = frame * stride + inBuffer
                    var y = Double(data[i]) * gain
                    for (n, band) in bands.enumerated() {
                        let z = base + n * 2
                        let x = y
                        y = band.b0 * x + memory[z]
                        memory[z] = band.b1 * x - band.a1 * y + memory[z + 1]
                        memory[z + 1] = band.b2 * x - band.a2 * y
                    }
                    data[i] = Float(max(-1, min(1, y)))
                }
                channel += 1
            }
        }
        if let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self), frames > 0 {
            let stride = Int(buffers.first!.mNumberChannels)
            var sum: Float = 0
            for frame in 0..<frames { sum += first[frame * stride] * first[frame * stride] }
            let rms = (sum / Float(frames)).squareRoot()
            shared.level.withLock { $0 = rms }
        }
    }
}
