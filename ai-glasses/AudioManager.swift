//
//  AudioManager.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "AudioManager")

// MARK: - Audio Recording State

enum AudioRecordingState: Equatable {
    case idle
    case recording
    case finishing
    case error(String)
}

// MARK: - Audio Manager

/// Manages HFP audio session for Meta Wearables microphone access and audio recording
final class AudioManager: NSObject {
    
    private let audioSession = AVAudioSession.sharedInstance()
    private var audioRecorder: AVAudioRecorder?
    private var currentRecordingURL: URL?
    
    private(set) var isConfigured: Bool = false
    private(set) var recordingState: AudioRecordingState = .idle
    
    // Callback for state changes
    var onRecordingStateChanged: ((AudioRecordingState) -> Void)?
    
    // MARK: - Audio Session Configuration
    
    /// Configure audio session for HFP (Hands-Free Profile) to access glasses microphone
    /// Must be called BEFORE starting a stream session
    func configureForHFP() throws {
        logger.info("🎤 Configuring audio session for HFP...")
        
        do {
            // Set category to playAndRecord with Bluetooth option for HFP
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .defaultToSpeaker]
            )
            
            // Activate the audio session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            isConfigured = true
            logger.info("✅ Audio session configured for HFP")
            
            // Log available inputs
            if let inputs = audioSession.availableInputs {
                for input in inputs {
                    logger.info("🎤 Available input: \(input.portName) (\(input.portType.rawValue))")
                }
            }
            
        } catch {
            isConfigured = false
            logger.error("❌ Failed to configure audio session: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Deactivate audio session
    func deactivate() {
        logger.info("🎤 Deactivating audio session...")
        
        // Stop recording if in progress
        if recordingState == .recording {
            cancelRecording()
        }
        
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            isConfigured = false
            logger.info("✅ Audio session deactivated")
        } catch {
            logger.warning("⚠️ Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
    
    /// Check if Bluetooth audio input is available
    func isBluetoothInputAvailable() -> Bool {
        guard let inputs = audioSession.availableInputs else { return false }
        
        let bluetoothTypes: [AVAudioSession.Port] = [
            .bluetoothHFP,
            .bluetoothA2DP,
            .bluetoothLE
        ]
        
        return inputs.contains { input in
            bluetoothTypes.contains(input.portType)
        }
    }
    
    /// Get current audio input
    func getCurrentInput() -> AVAudioSessionPortDescription? {
        return audioSession.currentRoute.inputs.first
    }
    
    /// Get current audio input description for display
    func getCurrentInputDescription() -> String {
        guard let input = getCurrentInput() else {
            return "No input"
        }
        return "\(input.portName) (\(input.portType.rawValue))"
    }
    
    // MARK: - Audio Recording
    
    /// Start recording audio from Bluetooth microphone
    func startRecording() throws -> URL {
        guard recordingState == .idle else {
            throw AudioRecordingError.alreadyRecording
        }
        
        // Configure audio session if not already configured
        if !isConfigured {
            try configureForHFP()
        }
        
        // Create output file URL
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "audio_\(Date().timeIntervalSince1970).m4a"
        let outputURL = documentsDirectory.appendingPathComponent(fileName)
        
        // Audio recording settings (AAC format for good quality and compatibility)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: outputURL, settings: settings)
            audioRecorder?.delegate = self
            
            guard audioRecorder?.record() == true else {
                throw AudioRecordingError.recordingFailed
            }
            
            currentRecordingURL = outputURL
            recordingState = .recording
            onRecordingStateChanged?(recordingState)
            
            logger.info("🔴 Audio recording started: \(outputURL.lastPathComponent)")
            logger.info("🎤 Recording from: \(self.getCurrentInputDescription())")
            
            return outputURL
            
        } catch {
            logger.error("❌ Failed to start audio recording: \(error.localizedDescription)")
            throw AudioRecordingError.recordingFailed
        }
    }
    
    /// Stop recording and return the output URL
    func stopRecording() throws -> URL {
        guard recordingState == .recording else {
            throw AudioRecordingError.notRecording
        }
        
        guard let recorder = audioRecorder, let outputURL = currentRecordingURL else {
            throw AudioRecordingError.notRecording
        }
        
        recordingState = .finishing
        onRecordingStateChanged?(recordingState)
        
        recorder.stop()
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            recordingState = .error("Recording file not found")
            onRecordingStateChanged?(recordingState)
            throw AudioRecordingError.recordingFailed
        }
        
        recordingState = .idle
        onRecordingStateChanged?(recordingState)
        
        logger.info("✅ Audio recording stopped: \(outputURL.lastPathComponent)")
        
        audioRecorder = nil
        currentRecordingURL = nil
        
        return outputURL
    }
    
    /// Cancel recording and delete the file
    func cancelRecording() {
        guard let recorder = audioRecorder else { return }
        
        recorder.stop()
        
        // Delete the partial recording
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            logger.info("🗑️ Audio recording cancelled and deleted")
        }
        
        audioRecorder = nil
        currentRecordingURL = nil
        recordingState = .idle
        onRecordingStateChanged?(recordingState)
    }
    
    /// Get recording duration
    var recordingDuration: TimeInterval {
        return audioRecorder?.currentTime ?? 0
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioManager: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            logger.error("❌ Audio recording finished unsuccessfully")
            recordingState = .error("Recording failed")
            onRecordingStateChanged?(recordingState)
        }
    }
    
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        if let error = error {
            logger.error("❌ Audio encoder error: \(error.localizedDescription)")
            recordingState = .error(error.localizedDescription)
            onRecordingStateChanged?(recordingState)
        }
    }
}

// MARK: - Audio Recording Error

enum AudioRecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case recordingFailed
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording already in progress"
        case .notRecording:
            return "No recording in progress"
        case .recordingFailed:
            return "Failed to record audio"
        case .permissionDenied:
            return "Microphone permission denied"
        }
    }
}
