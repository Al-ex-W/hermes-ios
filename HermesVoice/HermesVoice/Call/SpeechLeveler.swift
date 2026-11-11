import Foundation

/// Levels one line of Hermes' speech as it is turned from 16-bit PCM into the player's float samples, so a line
/// spoken with a quiet audio tag (whisper, low, flat) is as audible as a normal one.
///
/// It is done here, on the phone, because this is where every sample is touched anyway (the conversion), a chunk
/// is in hand whole before any of it plays (so its level is known ahead, with no added delay), and the audio the
/// phone keeps for Repeat goes through the same path. The host would have to do the same arithmetic in Python on
/// a stream it only forwards.
///
/// How: the line's speech level is its RMS over the 20 ms blocks that hold speech (blocks under `gateDB` are
/// silence and don't count), from the start of the line. A line whose level is under `targetDB` gets one gain
/// that brings it there, at most `maxGainDB`. A line at or over the target is not touched at all: its samples are
/// the plain conversion, bit for bit.
///
/// No pumping: the gain follows the level of the whole line so far, not of the last syllable, and rises by at
/// most `releaseDBPerSecond`. (It is set outright once, when the line's first speech has been measured, before
/// that speech plays.) A quiet stretch inside a normal line, such as a whisper tag half way, is levelled as a line
/// of its own once it has lasted `segmentSeconds` at `segmentDropDB` under the line so far.
///
/// No clipping: a loud passage after a quiet start pulls the gain down within `attackSeconds` (the block is
/// measured before it is played), the gain never lifts the last second's peaks over `ceiling`, and whatever is
/// amplified goes through a soft limiter that stays under full scale.
struct SpeechLeveler {
    /// The speech level a quiet line is raised to, in dBFS. Normal ElevenLabs speech is expected at or above it.
    static let targetDB: Float = -24
    /// The most a line is ever raised.
    static let maxGainDB: Float = 15
    /// A block under this level is silence between words, not speech.
    static let gateDB: Float = -50
    static let blockSeconds = 0.02
    /// Speech that has to be measured before the line's level counts (a syllable: its soft onset alone would
    /// make a normal line look quiet).
    static let minSpeechSeconds = 0.15
    /// The window the recent level and the recent peaks are taken over.
    static let windowSeconds = 1.0
    /// A stretch this long, this far under the line's level so far, is levelled on its own from then on.
    static let segmentSeconds = 0.6
    static let segmentDropDB: Float = 8
    /// How fast the gain may rise, and how fast it falls.
    static let releaseDBPerSecond: Float = 6
    static let attackSeconds = 0.005
    /// Amplified peaks of the last second are kept under this, and the soft limiter bends from `knee` on and
    /// never passes `top`.
    static let ceiling: Float = 0.95
    static let knee: Float = 0.89
    static let top: Float = 0.99

    private struct Block {
        var energy: Double
        var frames: Int
        var peak: Float
        var speech: Bool
    }

    private let blockFrames: Int
    private let attackFrames: Int
    private let minSpeechFrames: Int
    private let windowFrames: Int
    private let segmentFrames: Int
    /// Sum of squares and frame count of the speech measured so far (of the line, or of its current stretch).
    private var energy: Double = 0
    private var speechFrames = 0
    /// The same for the whole line, for `levelDB`.
    private var lineEnergy: Double = 0
    private var lineSpeechFrames = 0
    private var window: [Block] = []
    private var windowTotal = 0
    /// The gain in effect at the end of what was processed so far.
    private(set) var gain: Float = 1
    /// The line's level has been measured and its gain set.
    private var acquired = false
    /// Samples of the line that went through so far.
    private var processed = 0

    init(sampleRate: Double) {
        let rate = sampleRate > 0 ? sampleRate : 24_000
        blockFrames = max(1, Int(rate * Self.blockSeconds))
        attackFrames = max(1, Int(rate * Self.attackSeconds))
        minSpeechFrames = max(1, Int(rate * Self.minSpeechSeconds))
        windowFrames = max(1, Int(rate * Self.windowSeconds))
        segmentFrames = max(1, Int(rate * Self.segmentSeconds))
    }

    /// The line's speech level as it arrived, in dBFS; nil while no speech was measured.
    var levelDB: Double? {
        lineSpeechFrames > 0 ? 10 * log10(max(lineEnergy / Double(lineSpeechFrames), 1e-12)) : nil
    }

    /// The gain in effect now, in dB (0 for a line that is not touched).
    var gainDB: Double { 20 * log10(Double(max(gain, 1e-6))) }

    /// Converts `samples` to floats in `out` (which holds at least as many), levelled.
    mutating func process(_ samples: UnsafeBufferPointer<Int16>, into out: UnsafeMutablePointer<Float>) {
        let count = samples.count
        guard count > 0 else { return }
        // First pass: measure every block of the chunk, and what gain each one asks for.
        var wanted: [Float] = []
        wanted.reserveCapacity(count / blockFrames + 1)
        var acquiredAt: Int?
        var start = 0
        while start < count {
            let end = min(count, start + blockFrames)
            measure(samples, start, end)
            if !acquired, speechFrames >= minSpeechFrames {
                acquired = true
                acquiredAt = wanted.count
            }
            wanted.append(acquired ? wantedGain() : 1)
            start = end
        }
        // The line's first speech was measured in this chunk, and none of the chunk has played: it all gets
        // the gain that speech asks for. From its first sample when it opens the line; else the gain moves there
        // over the chunk's first block (what came before played as it was).
        var settingIn = false
        if let acquiredAt {
            let first = wanted[acquiredAt]
            for index in 0..<acquiredAt { wanted[index] = first }
            if processed == 0 { gain = first } else { settingIn = true }
        }
        processed += count
        // Second pass: apply, block by block.
        let risePerBlock = powf(10, Self.releaseDBPerSecond * Float(Self.blockSeconds) / 20)
        start = 0
        var block = 0
        while start < count {
            let end = min(count, start + blockFrames)
            let target = wanted[block]
            if gain == 1, target == 1 {
                for index in start..<end { out[index] = Float(Int16(littleEndian: samples[index])) / 32768 }
            } else {
                let from = gain
                // Down within the attack; up no faster than the release.
                let to = target < from || settingIn ? target : min(target, from * risePerBlock)
                let ramp = target < from ? min(attackFrames, end - start) : end - start
                settingIn = false
                for index in start..<end {
                    let step = index - start
                    let now = step >= ramp ? to : from + (to - from) * Float(step + 1) / Float(ramp)
                    out[index] = Self.limit(Float(Int16(littleEndian: samples[index])) / 32768 * now)
                }
                gain = to
            }
            start = end
            block += 1
        }
    }

    /// Convenience for whole arrays (tests).
    mutating func process(_ samples: [Int16]) -> [Float] {
        var out = [Float](repeating: 0, count: samples.count)
        samples.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                if let base = output.baseAddress { process(input, into: base) }
            }
        }
        return out
    }

    /// The soft limiter: unchanged up to `knee`, then bent so that nothing reaches full scale.
    static func limit(_ sample: Float) -> Float {
        let size = abs(sample)
        guard size > knee else { return sample }
        let bent = knee + (top - knee) * tanhf((size - knee) / (top - knee))
        return sample < 0 ? -bent : bent
    }

    private mutating func measure(_ samples: UnsafeBufferPointer<Int16>, _ start: Int, _ end: Int) {
        var sum: Double = 0
        var peak: Float = 0
        for index in start..<end {
            let value = Float(Int16(littleEndian: samples[index])) / 32768
            sum += Double(value * value)
            peak = max(peak, abs(value))
        }
        let frames = end - start
        let gate = Double(powf(10, Self.gateDB / 10))
        let speech = sum / Double(frames) >= gate
        if speech {
            energy += sum
            speechFrames += frames
            lineEnergy += sum
            lineSpeechFrames += frames
        }
        window.append(Block(energy: sum, frames: frames, peak: peak, speech: speech))
        windowTotal += frames
        while windowTotal - window[0].frames >= windowFrames {
            windowTotal -= window.removeFirst().frames
        }
        // A stretch well under the line so far (a whisper tag half way through): level it as its own line.
        let recent = recentSpeech()
        if acquired, recent.frames >= segmentFrames, speechFrames > recent.frames {
            let drop = Double(powf(10, -Self.segmentDropDB / 10))
            if recent.energy / Double(recent.frames) < energy / Double(speechFrames) * drop {
                energy = recent.energy
                speechFrames = recent.frames
            }
        }
    }

    private func recentSpeech() -> (energy: Double, frames: Int) {
        var sum: Double = 0
        var frames = 0
        for block in window where block.speech {
            sum += block.energy
            frames += block.frames
        }
        return (sum, frames)
    }

    /// The gain the speech measured so far asks for: up to the target, never past what the last second's peaks
    /// leave room for, and never down (a loud line is left alone).
    private func wantedGain() -> Float {
        guard speechFrames > 0 else { return 1 }
        var level = (energy / Double(speechFrames)).squareRoot()
        // A passage far louder than the line so far counts at once (less 6 dB), before the line's level catches up.
        let recent = recentSpeech()
        if recent.frames > 0 { level = max(level, (recent.energy / Double(recent.frames)).squareRoot() / 2) }
        let target = Double(powf(10, Self.targetDB / 20))
        var wanted = Float(target / max(level, 1e-9))
        let peak = window.reduce(Float(0)) { max($0, $1.peak) }
        if peak > 0 { wanted = min(wanted, Self.ceiling / peak) }
        return min(max(wanted, 1), powf(10, Self.maxGainDB / 20))
    }
}
