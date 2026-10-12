import AVFoundation
import Foundation

/// Two-channel playback like the original mixer (FUN_00416b44): channel 0 for
/// speech and sound effects (one at a time, a new sound stops the old one),
/// channel 1 for music. All game audio is 8-bit mono PCM; it is converted to
/// float and resampled to a common rate here.
final class AudioSystem {
    private let engine = AVAudioEngine()
    private let speechNode = AVAudioPlayerNode()
    private let musicNode = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
    private var speechGeneration = 0
    private var musicGeneration = 0
    private(set) var speechPlaying = false
    private(set) var musicPlaying = false
    private(set) var currentSpeechId = 0
    private var available = false
    var enabled = true

    init() {
        engine.attach(speechNode)
        engine.attach(musicNode)
        engine.connect(speechNode, to: engine.mainMixerNode, format: format)
        engine.connect(musicNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            available = true
        } catch {
            NSLog("Audio unavailable: \(error)")
        }
    }

    private func buffer(_ w: WaveSound) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / Double(max(1, w.sampleRate))
        let outCount = max(1, Int(Double(w.samples.count) * ratio))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outCount)),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(outCount)
        w.samples.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            let n = src.count
            for i in 0..<outCount {
                let pos = Double(i) / ratio
                let a = min(n - 1, Int(pos)), b = min(n - 1, a + 1)
                let t = Float(pos - Double(a))
                let va = (Float(src[a]) - 128) / 128, vb = (Float(src[b]) - 128) / 128
                out[i] = va + (vb - va) * t
            }
        }
        return buf
    }

    /// Speech_Play (FUN_004351c2): stop channel 0 and start WAVE `id`.
    func playSpeech(_ wave: WaveSound?, id: Int) {
        stopSpeech()
        guard enabled, available, let wave, let buf = buffer(wave) else { return }
        speechGeneration += 1
        let gen = speechGeneration
        speechPlaying = true
        currentSpeechId = id
        speechNode.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.speechGeneration == gen else { return }
                self.speechPlaying = false
            }
        }
        speechNode.play()
    }

    func stopSpeech() {
        speechGeneration += 1
        speechNode.stop()
        speechPlaying = false
        currentSpeechId = 0
    }

    func playMusic(_ wave: WaveSound?, loop: Bool) {
        stopMusic()
        guard enabled, available, let wave, let buf = buffer(wave) else { return }
        musicGeneration += 1
        let gen = musicGeneration
        musicPlaying = true
        musicNode.scheduleBuffer(buf, at: nil, options: loop ? .loops : []) { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.musicGeneration == gen else { return }
                self.musicPlaying = false
            }
        }
        musicNode.play()
    }

    func stopMusic() {
        musicGeneration += 1
        musicNode.stop()
        musicPlaying = false
    }
}
