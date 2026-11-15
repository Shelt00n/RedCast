import Foundation

// All types here work on a 16 kHz mono stream cut into 30 ms frames.
// Not thread-safe: feed them from one serial queue.

private let sampleRate = 16_000
private let frameLength = 480          // 30 ms
private let frameMs = 30.0

/// Energy voice detector with an adaptive noise floor.
struct VoiceDetector {
    private(set) var noiseFloor: Float = 0.001

    static func rms(_ frame: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for s in frame { sum += s * s }
        return (sum / Float(max(1, frame.count))).squareRoot()
    }

    /// `adapt` — let quiet frames move the noise floor (only while nobody is talking).
    mutating func isSpeech(_ frame: ArraySlice<Float>, adapt: Bool) -> Bool {
        let rms = Self.rms(frame)
        let speech = rms > max(noiseFloor * 3.0, 0.004)
        if !speech && adapt { noiseFloor = noiseFloor * 0.97 + rms * 0.03 }
        return speech
    }
}

/// Cuts a long phrase into pieces at natural pauses, so each piece is recognised while
/// the person is still talking. When they stop, only the short tail is left to recognise.
struct ChunkTracker {
    /// A pause this long (360 ms) inside a phrase is a good cut point.
    var pauseFrames = 12
    /// Only cut once the piece has this much voice (1.8 s): tiny pieces recognise worse.
    var minVoicedFrames = 60
    /// Never let a piece grow past this, even without a pause.
    var maxPieceSamples = sampleRate * 24

    private(set) var pieceStart = 0
    private(set) var voicedFrames = 0
    private var silenceRun = 0
    private var cutInThisPause = false

    mutating func reset(start: Int = 0) {
        pieceStart = start
        voicedFrames = 0
        silenceRun = 0
        cutInThisPause = false
    }

    /// Call after appending a frame; `count` is the buffer length now.
    /// Returns where to cut (buffer index) when a piece is complete.
    mutating func observe(isSpeech: Bool, count: Int) -> Int? {
        if isSpeech {
            voicedFrames += 1
            silenceRun = 0
            cutInThisPause = false
        } else {
            silenceRun += 1
        }
        if !cutInThisPause && silenceRun >= pauseFrames && voicedFrames >= minVoicedFrames {
            cutInThisPause = true
            // Cut in the middle of the pause: no word is split.
            return max(pieceStart + 1, count - (silenceRun / 2) * frameLength)
        }
        if count - pieceStart >= maxPieceSamples && isSpeech == false {
            return count
        }
        if count - pieceStart >= maxPieceSamples + sampleRate * 2 {
            return count     // 2 s past the limit without any quiet frame: cut anyway
        }
        return nil
    }

    mutating func didCut(at index: Int) {
        pieceStart = index
        voicedFrames = 0
    }

    /// The rest after the last cut has some voice worth recognising.
    var tailHasVoice: Bool { voicedFrames >= 5 }
}

/// «Авто» mode: splits a stream into phrases (a phrase ends after `silenceMs` of silence)
/// and, inside a phrase, into pieces at short pauses.
final class SpeechSegmenter: @unchecked Sendable {
    var silenceMs: Double = 700
    /// false in «По кнопкам» mode: audio is ignored by the automatic splitter.
    var active = true

    /// A new phrase started (its id).
    var onSpeechStart: (@Sendable (Int) -> Void)?
    /// Audio of the piece being spoken right now (for the live caption).
    var onPartial: (@Sendable (Int, [Float]) -> Void)?
    /// A finished piece inside the phrase.
    var onPiece: (@Sendable (Int, [Float]) -> Void)?
    /// The phrase ended: the remaining audio (may be empty) and whether it has voice.
    var onFinal: (@Sendable (Int, [Float], Bool) -> Void)?
    /// The «phrase» was only a click or a breath: forget it.
    var onDiscard: (@Sendable (Int) -> Void)?

    private let preRollFrames = 10               // keep 300 ms before speech onset
    private let minSpeechMs = 250.0
    private let maxUtteranceSamples = sampleRate * 90
    private let partialEverySamples = 21_000     // live caption every ~1.3 s
    private let partialWindowSamples = sampleRate * 8

    private var detector = VoiceDetector()
    private var tracker = ChunkTracker()
    private var pending: [Float] = []
    private var preRoll: [[Float]] = []
    private var utterance: [Float] = []
    private var inSpeech = false
    private var onsetFrames = 0
    private var silenceFrames = 0
    private var speechFrames = 0
    private var samplesSincePartial = 0
    private var piecesSent = 0
    private var utteranceID = 0

    func reset() {
        pending.removeAll()
        preRoll.removeAll()
        utterance.removeAll()
        inSpeech = false
        onsetFrames = 0
        silenceFrames = 0
        speechFrames = 0
        samplesSincePartial = 0
        piecesSent = 0
        tracker.reset()
    }

    func append(_ samples: [Float]) {
        guard active else { return }
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= frameLength {
            process(pending[offset..<offset + frameLength])
            offset += frameLength
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    /// Force-close the current phrase (hotkey «ответить сейчас»).
    func flush() {
        if inSpeech { finish(endedBySilence: false) }
    }

    private func process(_ frame: ArraySlice<Float>) {
        let isSpeech = detector.isSpeech(frame, adapt: !inSpeech)

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
                return
            }
            if utterance.count >= maxUtteranceSamples {
                finish(endedBySilence: false)
                return
            }
            if let cut = tracker.observe(isSpeech: isSpeech, count: utterance.count) {
                let piece = Array(utterance[tracker.pieceStart..<cut])
                tracker.didCut(at: cut)
                piecesSent += 1
                samplesSincePartial = 0
                onPiece?(utteranceID, piece)
            } else if samplesSincePartial >= partialEverySamples {
                samplesSincePartial = 0
                let current = utterance.count - tracker.pieceStart
                if current >= sampleRate {
                    onPartial?(utteranceID, Array(utterance[max(tracker.pieceStart, utterance.count - partialWindowSamples)...]))
                }
            }
        } else {
            preRoll.append(Array(frame))
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
                    piecesSent = 0
                    tracker.reset()
                    for _ in 0..<onsetFrames { _ = tracker.observe(isSpeech: true, count: utterance.count) }
                    utteranceID += 1
                    onSpeechStart?(utteranceID)
                }
            } else {
                onsetFrames = 0
            }
        }
    }

    private func finish(endedBySilence: Bool) {
        let id = utteranceID
        let voiced = Double(speechFrames) * frameMs
        let start = tracker.pieceStart
        var tail = start < utterance.count ? Array(utterance[start...]) : []
        let tailHasVoice = tracker.tailHasVoice
        let sent = piecesSent
        inSpeech = false
        utterance.removeAll()
        onsetFrames = 0
        silenceFrames = 0
        speechFrames = 0
        samplesSincePartial = 0
        piecesSent = 0
        tracker.reset()

        if sent == 0 && voiced < minSpeechMs {
            onDiscard?(id)
            return
        }
        // Trim most of the trailing silence (keep 200 ms): less audio, faster decode.
        let trailing = Int(silenceMs / 1000 * Double(sampleRate)) - sampleRate / 5
        if endedBySilence && trailing > 0 && tail.count > trailing * 2 { tail.removeLast(trailing) }
        onFinal?(id, tailHasVoice ? tail : [], tailHasVoice)
    }
}

/// «По кнопкам» mode: records everything from the first press to the second one.
/// Keeps the last 1.5 s before the press, so the first word is never cut, and sends
/// finished pieces (at natural pauses) for recognition while the recording goes on.
final class ManualRecorder: @unchecked Sendable {
    var onPartial: (@Sendable (Int, [Float]) -> Void)?
    var onPiece: (@Sendable (Int, [Float]) -> Void)?

    private let prerollSamples = 24_000
    private let partialEverySamples = 21_000
    private var preroll: [Float] = []
    private var pending: [Float] = []
    private var buffer: [Float] = []
    private var recording = false
    private var sincePartial = 0
    private var detector = VoiceDetector()
    private var tracker = ChunkTracker()
    private var recordingID = 0

    func append(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        var offset = 0
        while pending.count - offset >= frameLength {
            process(pending[offset..<offset + frameLength])
            offset += frameLength
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    private func process(_ frame: ArraySlice<Float>) {
        let isSpeech = detector.isSpeech(frame, adapt: true)
        guard recording else {
            preroll.append(contentsOf: frame)
            if preroll.count > prerollSamples { preroll.removeFirst(preroll.count - prerollSamples) }
            return
        }
        buffer.append(contentsOf: frame)
        sincePartial += frame.count
        if let cut = tracker.observe(isSpeech: isSpeech, count: buffer.count) {
            let piece = Array(buffer[tracker.pieceStart..<cut])
            tracker.didCut(at: cut)
            sincePartial = 0
            onPiece?(recordingID, piece)
        } else if sincePartial >= partialEverySamples {
            sincePartial = 0
            if buffer.count - tracker.pieceStart >= sampleRate {
                onPartial?(recordingID, Array(buffer[max(tracker.pieceStart, buffer.count - sampleRate * 8)...]))
            }
        }
    }

    /// Starts a recording with the given id (pieces and captions carry it).
    func start(id: Int) {
        recordingID = id
        buffer = preroll + pending
        pending.removeAll()
        preroll.removeAll()
        sincePartial = 0
        tracker.reset()
        recording = true
    }

    /// Stops and returns the audio after the last piece, and whether it has voice.
    func stop() -> (tail: [Float], hasVoice: Bool, piecesSent: Bool) {
        recording = false
        buffer.append(contentsOf: pending)
        pending.removeAll()
        let start = tracker.pieceStart
        let tail = start < buffer.count ? Array(buffer[start...]) : []
        let piecesSent = start > 0
        // Without pieces the whole recording is the tail: always recognise it.
        let hasVoice = !piecesSent || tracker.tailHasVoice
        buffer.removeAll()
        tracker.reset()
        return (tail, hasVoice, piecesSent)
    }

    func cancel() {
        recording = false
        buffer.removeAll()
        tracker.reset()
    }
}
