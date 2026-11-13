import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// Converts any PCM buffer to 16 kHz mono Float32 — the format Whisper expects.
final class Resampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if inputFormat == nil || inputFormat! != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            inputFormat = buffer.format
        }
        guard let converter, buffer.frameLength > 0 else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 256)
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }
}

extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(self),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var asbd = asbdPointer.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    case micDenied
    case micNotFound
    var errorDescription: String? {
        switch self {
        case .micNotFound: return "Выбранный микрофон не найден или занят. Выберите другой в «Настройки → Распознавание речи → Микрофон»."
        case .noDisplay: return "Не найден дисплей для захвата звука."
        case .micDenied: return "Нет доступа к микрофону (Системные настройки → Конфиденциальность → Микрофон)."
        }
    }
}

/// Captures everything the Mac plays (Zoom / Meet / Teams / browser) via ScreenCaptureKit.
/// No virtual audio driver (BlackHole etc.) is needed.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSamples: (@Sendable ([Float]) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private var stream: SCStream?
    var isRunning: Bool { stream != nil }
    private let queue = DispatchQueue(label: "redcast.system-audio", qos: .userInteractive)
    private let resampler = Resampler()

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only need audio: keep the video part as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.pcmBuffer() else { return }
        let samples = resampler.convert(pcm)
        if !samples.isEmpty { onSamples?(samples) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

/// Microphone (the candidate's own voice).
/// A microphone (any input device: built-in, AirPods, USB, audio interface…).
struct AudioInputDevice: Identifiable, Hashable {
    let id: String          // CoreAudio UID — stable across reboots
    let name: String
    let deviceID: AudioDeviceID
}

enum AudioDevices {
    static func inputs() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return AudioInputDevice(id: uid, name: name, deviceID: id)
        }
    }

    static func defaultInputName() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputs().first { $0.id == uid }?.deviceID
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Microphone (the candidate's own voice).
final class MicCapture {
    var onSamples: (@Sendable ([Float]) -> Void)?
    /// Input level 0…1, about 10 times per second (for the meter in Settings).
    var onLevel: (@Sendable (Float) -> Void)?
    /// CoreAudio UID of the chosen microphone; empty = system default.
    var deviceUID = ""
    var echoCancellation = true
    var isRunning: Bool { running }

    private var engine = AVAudioEngine()
    private let resampler = Resampler()
    private var running = false
    private var levelPeak: Float = 0
    private var levelSamples = 0

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    func start() throws {
        guard !running else { return }
        if echoCancellation {
            do {
                try startEngine(voiceProcessing: true)
                return
            } catch {
                // Some microphones / aggregate devices do not support Apple's echo cancellation.
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }
        try startEngine(voiceProcessing: false)
    }

    private func startEngine(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()          // fresh engine: the device may have changed
        let input = engine.inputNode
        if voiceProcessing {
            // Apple's acoustic echo cancellation: removes the interviewer's voice coming from the speakers.
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        if !deviceUID.isEmpty {
            guard let id = AudioDevices.deviceID(forUID: deviceUID) else { throw CaptureError.micNotFound }
            guard let unit = input.audioUnit else { throw CaptureError.micNotFound }
            var dev = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw CaptureError.micNotFound }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.micNotFound }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.resampler.convert(buffer)
            guard !samples.isEmpty else { return }
            self.onSamples?(samples)
            self.reportLevel(samples)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    private func reportLevel(_ samples: [Float]) {
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        levelPeak = max(levelPeak, rms)
        levelSamples += samples.count
        if levelSamples >= 1_600 {                      // ~100 ms at 16 kHz
            let level = min(1, levelPeak * 8)
            onLevel?(level)
            levelPeak = 0
            levelSamples = 0
        }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        onLevel?(0)
    }
}
