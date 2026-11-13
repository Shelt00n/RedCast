import Foundation

/// Energy-based voice activity detector with an adaptive noise floor.
/// Splits a 16 kHz stream into utterances: an utterance ends after `silenceMs` of silence.
/// While someone is talking it periodically emits the audio so far (for live captions).
/// Not thread-safe: feed it from a single serial queue.
final class SpeechSegmenter: @unchecked Sendable {
    var silenceMs: Double = 700
    /// false in «По кнопкам» mode: audio is ignored by the automatic splitter.
    var active = true
    var onPartial: (@Sendable ([Float]) -> Void)?
    var onFinal: (@Sendable ([Float]) -> Void)?
    var onSpeechStart: (@Sendable () -> Void)?

    private let sampleRate = 16_000
    private let frameLength = 480                // 30 ms
    private let frameMs = 30.0
    private let preRollFrames = 10               // keep 300 ms before speech onset
    private let minSpeechMs = 250.0
    private let maxUtteranceSamples = 16_000 * 28
    private let partialEverySamples = 24_000     // live caption every ~1.5 s
    private let partialWindowSamples = 16_000 * 8 // live caption decodes only the last 8 s

    private var pending: [Float] = []
    private var preRoll: [[Float]] = []
    private var utterance: [Float] = []
    private var inSpeech = false
    private var onsetFrames = 0
    private var silenceFrames = 0
    private var speechFrames = 0
    private var samplesSincePartial = 0
    private var noiseFloor: Float = 0.001

    func reset() {
        pending.removeAll()
        preRoll.removeAll()
        utterance.removeAll()
        inSpeech = false
        onsetFrames = 0
        silenceFrames = 0
        speechFrames = 0
        samplesSincePartial = 0
    }

    func append(_ samples: [Float]) {
        guard active else { return }
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= frameLength {
            process(Array(pending[offset..<offset + frameLength]))
            offset += frameLength
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    /// Force-close the current utterance (e.g. on "answer now" hotkey).
    func flush() {
        if inSpeech { finish(endedBySilence: false) }
    }

    private func process(_ frame: [Float]) {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        let threshold = max(noiseFloor * 3.0, 0.004)
        let isSpeech = rms > threshold

        if inSpeech {
            utterance.append(contentsOf: frame)
            samplesSincePartial += frame.count
            if isSpeech {
                silenceFrames = 0
                speechFrames += 1
            } else {
                silenceFrames += 1
            }
            if Double(silenceFrames) * frameMs >= silenceMs {
                finish(endedBySilence: true)
            } else if utterance.count >= maxUtteranceSamples {
                finish(endedBySilence: false)
            } else if samplesSincePartial >= partialEverySamples {
                samplesSincePartial = 0
                onPartial?(Array(utterance.suffix(partialWindowSamples)))
            }
        } else {
            preRoll.append(frame)
            if preRoll.count > preRollFrames { preRoll.removeFirst() }
            if isSpeech {
                onsetFrames += 1
                if onsetFrames >= 3 {               // ~90 ms of voice → speech started
                    inSpeech = true
                    utterance = preRoll.flatMap { $0 }
                    preRoll.removeAll()
                    speechFrames = onsetFrames
                    silenceFrames = 0
                    samplesSincePartial = 0
                    onSpeechStart?()
                }
            } else {
                onsetFrames = 0
                // Track background noise only while nobody is talking.
                noiseFloor = noiseFloor * 0.97 + rms * 0.03
            }
        }
    }

    private func finish(endedBySilence: Bool) {
        let audio = utterance
        let voiced = Double(speechFrames) * frameMs
        inSpeech = false
        utterance.removeAll()
        onsetFrames = 0
        silenceFrames = 0
        speechFrames = 0
        samplesSincePartial = 0
        guard voiced >= minSpeechMs else { return }
        // Trim most of the trailing silence (keep 200 ms) — less audio = faster decode.
        let trailing = Int(silenceMs / 1000 * Double(sampleRate)) - sampleRate / 5
        let trimmed = endedBySilence && trailing > 0 && audio.count > trailing * 2 ? Array(audio.dropLast(trailing)) : audio
        onFinal?(trimmed)
    }
}

/// «По кнопкам» mode: records everything from the button press until the second press.
/// Keeps the last 1.5 s before the press so the first word is never cut.
/// Not thread-safe: use from the same serial queue as the capture callback.
final class ManualRecorder: @unchecked Sendable {
    var onPartial: (@Sendable ([Float]) -> Void)?

    private let prerollSamples = 24_000
    private let partialEverySamples = 24_000
    private var preroll: [Float] = []
    private var buffer: [Float] = []
    private var recording = false
    private var sincePartial = 0

    func append(_ samples: [Float]) {
        if recording {
            buffer.append(contentsOf: samples)
            sincePartial += samples.count
            if sincePartial >= partialEverySamples {
                sincePartial = 0
                onPartial?(Array(buffer.suffix(16_000 * 8)))
            }
        } else {
            preroll.append(contentsOf: samples)
            if preroll.count > prerollSamples { preroll.removeFirst(preroll.count - prerollSamples) }
        }
    }

    func start() {
        buffer = preroll
        preroll.removeAll()
        sincePartial = 0
        recording = true
    }

    func stop() -> [Float] {
        recording = false
        let out = buffer
        buffer.removeAll()
        return out
    }

    func cancel() {
        recording = false
        buffer.removeAll()
    }
}
