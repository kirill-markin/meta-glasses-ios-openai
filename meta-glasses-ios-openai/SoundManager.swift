//
//  SoundManager.swift
//  meta-glasses-ios-openai
//
//  System sound notifications for Voice Agent events
//

@preconcurrency import AVFoundation
import os.log

@MainActor
final class SoundManager {
    static let shared = SoundManager()
    
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meta-glasses-ios-openai", category: "SoundManager")
    
    // Keep engine alive during playback
    private var activeEngine: AVAudioEngine?
    private var activePlayerNode: AVAudioPlayerNode?
    
    private init() {}
    
    /// Play sound when Voice Agent is ready to listen
    /// Short ascending two-tone chime (positive/ready feeling)
    func playReadySound() {
        logger.info("🔔 Playing ready sound")
        playTone(frequencies: [880, 1320], duration: 0.08, pause: 0.05)
    }
    
    /// Play sound when AI invokes a tool call
    /// Single short beep (action/processing feeling)
    func playToolCallSound() {
        logger.info("🔔 Playing tool call sound")
        playTone(frequencies: [660], duration: 0.1, pause: 0)
    }
    
    /// Play sound when Voice Agent session ends
    /// Short descending two-tone chime (ending/goodbye feeling)
    func playDisconnectSound() {
        logger.info("🔔 Playing disconnect sound")
        playTone(frequencies: [1320, 880], duration: 0.08, pause: 0.05)
    }
    
    /// Generate and play a sequence of sine wave tones
    private func playTone(frequencies: [Double], duration: Double, pause: Double) {
        let sampleRate: Double = 44100
        let amplitude: Float = 0.3
        
        // Generate all samples
        let samples = generateSamples(
            frequencies: frequencies,
            duration: duration,
            pause: pause,
            sampleRate: sampleRate,
            amplitude: amplitude
        )
        
        // Create audio buffer
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            logger.error("❌ Failed to create audio format/buffer")
            return
        }
        
        buffer.frameLength = AVAudioFrameCount(samples.count)
        
        // Copy samples to buffer
        if let channelData = buffer.floatChannelData?[0] {
            for (i, sample) in samples.enumerated() {
                channelData[i] = sample
            }
        }
        
        playBuffer(buffer)
    }
    
    /// Generate sine wave samples for given frequencies
    private func generateSamples(
        frequencies: [Double],
        duration: Double,
        pause: Double,
        sampleRate: Double,
        amplitude: Float
    ) -> [Float] {
        var allSamples: [Float] = []
        
        for (index, frequency) in frequencies.enumerated() {
            let frameCount = Int(sampleRate * duration)
            let fadeLength = min(100, frameCount / 4)
            
            // Generate sine wave for this frequency
            for i in 0..<frameCount {
                let phase = 2.0 * Double.pi * frequency * Double(i) / sampleRate
                let rawSample = amplitude * Float(sin(phase))
                
                // Apply fade envelope to avoid clicks
                let envelope = calculateEnvelope(index: i, frameCount: frameCount, fadeLength: fadeLength)
                allSamples.append(rawSample * envelope)
            }
            
            // Add pause between tones (except after last tone)
            if index < frequencies.count - 1 && pause > 0 {
                let pauseSamples = Int(sampleRate * pause)
                allSamples.append(contentsOf: [Float](repeating: 0, count: pauseSamples))
            }
        }
        
        return allSamples
    }
    
    /// Calculate fade in/out envelope
    private func calculateEnvelope(index: Int, frameCount: Int, fadeLength: Int) -> Float {
        if index < fadeLength {
            return Float(index) / Float(fadeLength)
        } else if index > frameCount - fadeLength {
            return Float(frameCount - index) / Float(fadeLength)
        }
        return 1.0
    }
    
    /// Play audio buffer using a temporary audio engine
    private func playBuffer(_ buffer: AVAudioPCMBuffer) {
        // Stop any previous playback
        activePlayerNode?.stop()
        activeEngine?.stop()
        
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        
        // Keep references to prevent deallocation
        activeEngine = engine
        activePlayerNode = playerNode
        
        engine.attach(playerNode)
        
        // Connect to main mixer with the buffer's format
        let mixer = engine.mainMixerNode
        engine.connect(playerNode, to: mixer, format: buffer.format)
        
        do {
            try engine.start()
            playerNode.play()
            
            // Schedule buffer and clean up when done
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cleanupAudio()
                }
            }
        } catch {
            logger.error("❌ Failed to play tone: \(error.localizedDescription)")
            cleanupAudio()
        }
    }
    
    /// Clean up audio resources after playback
    private func cleanupAudio() {
        activePlayerNode?.stop()
        activeEngine?.stop()
        activePlayerNode = nil
        activeEngine = nil
        logger.debug("🔔 Tone playback complete")
    }
}
