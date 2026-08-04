import AppKit
import AVFoundation

/// The macOS system sounds, grouped by character so the picker reads as a menu of
/// intents ("Gentle", "Bright", …) rather than an unordered list of Apple's names.
/// All ship with macOS, so nothing needs bundling.
enum SoundLibrary {

    static let defaultAsking = "Ping"
    static let defaultDone = "Purr"

    struct Group {
        let name: String
        let sounds: [String]
    }

    static let groups: [Group] = [
        Group(name: "Gentle",     sounds: ["Purr", "Pop", "Tink", "Bottle"]),
        Group(name: "Bright",     sounds: ["Ping", "Glass", "Blow", "Frog"]),
        Group(name: "Attention",  sounds: ["Hero", "Sosumi", "Submarine", "Funk"]),
        Group(name: "Low",        sounds: ["Basso", "Morse"])
    ]

    static var allSounds: [String] { groups.flatMap(\.sounds) }

    // MARK: - Volume mapping
    //
    // 80% on the slider is today's normal full volume; 80–100% applies real extra
    // digital gain above that. NSSound.volume was verified to silently clamp at
    // 1.0 (setting 1.25 or 2.0 both read back as exactly 1.0 — no effect), so
    // genuinely exceeding "normal full volume" requires scaling the actual sample
    // data via AVAudioEngine — see playViaEngine below.
    //
    // 1.25× was checked against measured peak levels of all 14 sounds before
    // picking it: the loudest, Hero, peaks at 0.535 (1.87× headroom), and the
    // quietest, Frog, at 0.173 (5.8× headroom) — every sound in the library has
    // more than enough headroom for a 1.25× boost with no clipping.
    static let boostMax: Float = 0.25

    static func gain(forSliderVolume v: Float) -> Float {
        let frac = min(max(v, 0), 1)
        if frac <= 0.8 { return frac / 0.8 }
        return 1.0 + (frac - 0.8) / 0.2 * boostMax
    }

    /// Plays at the user's configured volume (0...1, where >0.8 is a real boost
    /// above normal full volume — see the mapping above).
    ///
    /// The normal 0...1.0 gain range (slider 0-80%, which includes the default)
    /// goes through NSSound — the mechanism this app used before, proven to
    /// produce audible output. Only gain >1.0 (slider >80%, genuine amplification
    /// NSSound can't do at all) goes through AVAudioEngine. Scoping the newer,
    /// less-battle-tested engine path to only the case that actually needs it
    /// minimizes what can go wrong for the common case.
    static func play(_ name: String, volume: Float) {
        let g = gain(forSliderVolume: volume)
        guard g > 0 else { return }
        if g <= 1.0 {
            playViaNSSound(name, gain: g)
        } else {
            playViaEngine(name, gain: g)
        }
    }

    // MARK: - Normal range: NSSound

    /// Sounds currently playing, kept alive (with their delegate) until they
    /// finish. Without this, an NSSound with no other owner can be deallocated by
    /// ARC mid-playback — easy to trigger from a SwiftUI row whose view is torn
    /// down right after the tap (selecting a sound closes the popover immediately
    /// afterward), which cuts the sound off before it's actually heard.
    private static var playing: [(sound: NSSound, delegate: SoundCompletionDelegate)] = []

    private static func playViaNSSound(_ name: String, gain: Float) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = gain
        let delegate = SoundCompletionDelegate { [weak sound] in
            playing.removeAll { $0.sound === sound }
        }
        sound.delegate = delegate
        playing.append((sound, delegate))
        sound.play()
    }

    // MARK: - Boost range (>80%): AVAudioEngine, real sample-level gain

    private static let engine = AVAudioEngine()
    private static let player = AVAudioPlayerNode()
    private static var engineStarted = false
    private static var didAttach = false
    private static var bufferCache: [String: AVAudioPCMBuffer] = [:]

    @discardableResult
    private static func ensureEngineRunning() -> Bool {
        if engineStarted { return true }
        if !didAttach {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            didAttach = true
        }
        do {
            try engine.start()
            engineStarted = true
            return true
        } catch {
            return false
        }
    }

    private static func sourceBuffer(for name: String) -> AVAudioPCMBuffer? {
        if let cached = bufferCache[name] { return cached }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try? file.read(into: buffer)
        bufferCache[name] = buffer
        return buffer
    }

    private static func playViaEngine(_ name: String, gain: Float) {
        guard let source = sourceBuffer(for: name),
              let scaled = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return }

        scaled.frameLength = source.frameLength
        if let srcData = source.floatChannelData, let dstData = scaled.floatChannelData {
            for ch in 0..<Int(source.format.channelCount) {
                let s = srcData[ch], d = dstData[ch]
                for i in 0..<Int(source.frameLength) { d[i] = s[i] * gain }
            }
        }

        guard ensureEngineRunning() else { return }
        player.scheduleBuffer(scaled, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }
}

/// NSSoundDelegate needs a class; this just forwards completion so `playing` can
/// release the sound once it's actually done.
private final class SoundCompletionDelegate: NSObject, NSSoundDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func sound(_ sound: NSSound, didFinishPlaying finished: Bool) { onFinish() }
}
