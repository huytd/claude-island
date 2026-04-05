//
//  SoundGenerator.swift
//  ClaudeIsland
//
//  Generates 8-bit game-style sounds programmatically using raw waveform synthesis
//

import AVFoundation

/// Generates and plays retro 8-bit sounds on demand.
/// Each sound is a square/triangle waveform — the kind of stuff
/// you'd hear on a Game Boy or NES.
final class SoundGenerator: NSObject {
    static let shared = SoundGenerator()

    private var cachedBuffers: [BitSound: AVAudioPCMBuffer] = [:]
    private var activePlayers: [AVAudioPlayer] = []

    private override init() {
        super.init()
        // Pre-generate all sounds on init
        for sound in BitSound.allCases {
            cachedBuffers[sound] = generateBuffer(for: sound)
        }
    }

    // MARK: - Public API

    /// Play a sound by identifier. Returns immediately; sound plays asynchronously.
    func play(_ sound: BitSound) {
        let fileURL = makePlayerForSound(sound)
        guard let url = fileURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = 0.5
            player.delegate = self
            activePlayers.append(player)
            player.play()
        } catch {
            print("[SoundGenerator] Failed to play \(sound.rawValue): \(error)")
        }
    }

    // MARK: - Sound Generators

    /// Permission request — quick ascending arpeggio (square wave)
    func makePermissionSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let duration = 0.25
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)

            var freq: Double
            if fraction < 0.15 {
                freq = 523.25
            } else if fraction < 0.35 {
                let segFrac = (fraction - 0.15) / 0.2
                freq = 523.25 + (783.99 - 523.25) * segFrac
            } else if fraction < 0.65 {
                let segFrac = (fraction - 0.35) / 0.3
                freq = 783.99 + (1046.5 - 783.99) * segFrac
            } else {
                freq = 1046.5
            }

            let sample: Double = sin(2.0 * .pi * freq * t) > 0 ? 0.25 : -0.25
            let attack = fraction < 0.05 ? fraction / 0.05 : 1.0
            let release: Double = fraction > 0.85 ? 1.0 - (fraction - 0.85) / 0.15 : 1.0
            data[frame] = Float(sample * attack * release)
        }

        return buffer
    }

    /// Coin — cheerful two-tone (square wave, like Mario coin)
    func makeCoinSound() -> AVAudioPCMBuffer {
        // The classic Mario coin is two distinct notes: E6 then B6
        // Each note has its own phase, not a continuous sweep
        let sampleRate = 22_050.0
        let note1Duration = 0.06   // First note
        let note2Duration = 0.08   // Second note (slightly longer)
        let totalDuration = note1Duration + note2Duration
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)

            var freq: Double
            var vol: Double
            if t < note1Duration {
                freq = 987.77       // B5
                vol = 0.15
            } else {
                freq = 1318.51      // E6
                let note2Frac = (t - note1Duration) / note2Duration
                vol = 0.15 * (1.0 - note2Frac * 0.7)
            }

            // Soft square wave (reduced amplitude so it's less harsh)
            let sample: Double = sin(2.0 * .pi * freq * t) > 0 ? vol : -vol
            data[frame] = Float(sample)
        }

        return buffer
    }

    /// Short "blip" — generic UI click/select (square wave, very short)
    func makeBlipSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let duration = 0.06
        let frequency = 1200.0
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)
            let sample: Float = sin(2.0 * .pi * frequency * t) > 0 ? 0.15 : -0.15
            let envelope: Float = 1.0 - Float(fraction)
            data[frame] = sample * envelope
        }

        return buffer
    }

    /// Descending "buzzer" — error/negative feedback (square wave)
    func makeErrorSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let duration = 0.2
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)
            let freq = 440.0 - 200.0 * fraction
            let sample: Double = sin(2.0 * .pi * freq * t) > 0 ? 0.15 : -0.15
            let vol = 1.0 - fraction
            data[frame] = Float(sample * vol)
        }

        return buffer
    }

    /// Completion / waiting for input — cheerful power-up (triangle wave)
    func makeCompletionSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let duration = 0.3
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)

            var freq: Double
            if fraction < 0.2 {
                freq = 392.0
            } else if fraction < 0.45 {
                freq = 523.25
            } else if fraction < 0.7 {
                freq = 659.25
            } else {
                freq = 783.99
            }

            let phase = 2.0 * .pi * freq * t
            let triangle = asin(sin(phase)) * (2.0 / .pi)
            let attack: Double = fraction * 60.0 < 1.0 ? fraction * 60.0 : 1.0
            let release: Double = fraction > 0.7 ? 1.0 - (fraction - 0.7) / 0.3 : 1.0
            data[frame] = Float(Float(triangle) * 0.2 * Float(attack) * Float(release))
        }

        return buffer
    }

    /// Jump — cheerful two-tone (square wave, coin-like but different notes)
    func makeJumpSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let note1Duration = 0.06
        let note2Duration = 0.08
        let totalDuration = note1Duration + note2Duration
        let frameCount = AVAudioFrameCount(sampleRate * totalDuration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)

            var freq: Double
            var vol: Double
            if t < note1Duration {
                freq = 1174.66      // D6
                vol = 0.15
            } else {
                freq = 1567.98      // G6
                let note2Frac = (t - note1Duration) / note2Duration
                vol = 0.15 * (1.0 - note2Frac * 0.7)
            }

            let sample: Double = sin(2.0 * .pi * freq * t) > 0 ? vol : -vol
            data[frame] = Float(sample)
        }

        return buffer
    }

    /// Menu open — quick ascending tick (square wave)
    func makeMenuOpenSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let duration = 0.08
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)
            let freq = 800.0 + 400.0 * fraction
            let sample: Double = sin(2.0 * .pi * freq * t) > 0 ? 0.12 : -0.12
            let vol = 1.0 - fraction
            data[frame] = Float(sample * vol)
        }

        return buffer
    }

    /// Power up — longer ascending arpeggio (triangle wave)
    func makePowerUpSound() -> AVAudioPCMBuffer {
        let sampleRate = 22_050.0
        let duration = 0.35
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let fraction = Double(frame) / Double(frameCount)
            let freq = 261.63 + 784.87 * fraction
            let phase = 2.0 * .pi * freq * t
            let triangle = asin(sin(phase)) * (2.0 / .pi)
            let vol = 1.0 - fraction * 0.3
            data[frame] = Float(Float(triangle) * 0.2 * Float(vol))
        }

        return buffer
    }

    // MARK: - Buffer Generation

    /// Generate a PCM buffer for a given BitSound
    private func generateBuffer(for sound: BitSound) -> AVAudioPCMBuffer? {
        switch sound {
        case .permission:
            return makePermissionSound()
        case .completion:
            return makeCompletionSound()
        case .blip:
            return makeBlipSound()
        case .error:
            return makeErrorSound()
        case .coin:
            return makeCoinSound()
        case .jump:
            return makeJumpSound()
        case .powerUp:
            return makePowerUpSound()
        case .menuOpen:
            return makeMenuOpenSound()
        }
    }

    // MARK: - Playback

    /// Write buffer to a temp CAF file and return URL.
    private func makePlayerForSound(_ sound: BitSound) -> URL? {
        guard let buffer = cachedBuffers[sound] ?? generateBuffer(for: sound) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("8bit_\(sound.rawValue).caf")

        do {
            let audioFile = try AVAudioFile(
                forWriting: fileURL,
                settings: buffer.format.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try audioFile.write(from: buffer)
            audioFile.close()
            return fileURL
        } catch {
            print("[SoundGenerator] Failed to write CAF for \(sound.rawValue): \(error)")
            return nil
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension SoundGenerator: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        activePlayers.removeAll { $0 === player }
    }
}

// MARK: - BitSound Enum

/// Available 8-bit sounds, each mapped to a specific use case.
enum BitSound: String, CaseIterable {
    case permission   = "Permission"   // Rising arpegio — permission request
    case completion   = "Completion"   // Cheerful power-up — processing done
    case blip         = "Blip"         // Short click — generic UI
    case error        = "Error"        // Descending buzz — error
    case coin         = "Coin"         // Classic coin collect
    case jump         = "Jump"         // Jump sound
    case powerUp      = "Power Up"     // Longer power-up
    case menuOpen     = "Menu Open"    // Quick menu tick
}
