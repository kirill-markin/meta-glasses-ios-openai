//
//  VideoRecorder.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import Foundation
import AVFoundation
import UIKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "VideoRecorder")

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case recording
    case finishing
    case error(String)
}

// MARK: - Video Recorder

/// Records video frames and audio to a file
/// Marked as @unchecked Sendable because it handles synchronization internally via recordingQueue
final class VideoRecorder: @unchecked Sendable {
    
    // MARK: - Properties
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    private var isRecording: Bool = false
    private var startTime: CMTime?
    private var frameCount: Int = 0
    
    private let recordingQueue = DispatchQueue(label: "com.kirillmarkin.aiglasses.recording")
    
    private var videoSize: CGSize = .zero
    private var frameRate: Int = 24
    
    // Audio recording
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempAudioURL: URL?
    
    // MARK: - Public Methods
    
    /// Start recording video frames
    func startRecording(videoSize: CGSize, frameRate: Int) throws -> URL {
        guard !isRecording else {
            throw RecordingError.alreadyRecording
        }
        
        self.videoSize = videoSize
        self.frameRate = frameRate
        
        let outputURL = generateOutputURL()
        
        logger.info("🎬 Starting recording to: \(outputURL.lastPathComponent)")
        logger.info("📐 Video size: \(Int(videoSize.width))x\(Int(videoSize.height)), \(frameRate) fps")
        
        // Setup asset writer
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        // Video settings - high quality for 720p30
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000, // 6 Mbps for high quality 720p
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        
        // Pixel buffer adaptor for converting UIImage to video frames
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(videoSize.width),
            kCVPixelBufferHeightKey as String: Int(videoSize.height)
        ]
        
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput!,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        if assetWriter!.canAdd(videoInput!) {
            assetWriter!.add(videoInput!)
        }
        
        // Audio settings
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000
        ]
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if assetWriter!.canAdd(audioInput!) {
            assetWriter!.add(audioInput!)
        }
        
        // Start writing
        assetWriter!.startWriting()
        assetWriter!.startSession(atSourceTime: .zero)
        
        startTime = nil
        frameCount = 0
        isRecording = true
        
        // Start audio recording
        try startAudioRecording()
        
        logger.info("✅ Recording started")
        
        return outputURL
    }
    
    /// Append a video frame
    func appendFrame(image: UIImage) {
        guard isRecording,
              let videoInput = videoInput,
              let pixelBufferAdaptor = pixelBufferAdaptor else {
            return
        }
        
        recordingQueue.async { [weak self] in
            guard let self = self else { return }
            
            guard videoInput.isReadyForMoreMediaData else {
                return
            }
            
            // Calculate presentation time
            let presentationTime: CMTime
            if self.startTime == nil {
                self.startTime = CMTime(value: 0, timescale: CMTimeScale(self.frameRate))
                presentationTime = .zero
            } else {
                presentationTime = CMTime(
                    value: CMTimeValue(self.frameCount),
                    timescale: CMTimeScale(self.frameRate)
                )
            }
            
            // Convert UIImage to pixel buffer
            guard let pixelBuffer = self.createPixelBuffer(from: image) else {
                logger.warning("⚠️ Failed to create pixel buffer from frame")
                return
            }
            
            // Append pixel buffer
            if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
                self.frameCount += 1
                if self.frameCount == 1 || self.frameCount % 100 == 0 {
                    logger.debug("🎞️ Recorded frame #\(self.frameCount)")
                }
            }
        }
    }
    
    /// Stop recording and finalize the video file
    func stopRecording() async throws -> URL {
        guard isRecording else {
            throw RecordingError.notRecording
        }
        
        logger.info("⏹️ Stopping recording...")
        
        isRecording = false
        
        // Stop audio recording
        stopAudioRecording()
        
        guard let assetWriter = assetWriter else {
            throw RecordingError.writerNotInitialized
        }
        
        let outputURL = assetWriter.outputURL
        
        // Finish writing
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        
        await assetWriter.finishWriting()
        
        if assetWriter.status == .completed {
            logger.info("✅ Recording completed: \(self.frameCount) frames")
            
            // Merge audio if we have it
            if let tempAudioURL = tempAudioURL, FileManager.default.fileExists(atPath: tempAudioURL.path) {
                let mergedURL = try await mergeAudioWithVideo(videoURL: outputURL, audioURL: tempAudioURL)
                
                // Clean up temp files
                try? FileManager.default.removeItem(at: tempAudioURL)
                try? FileManager.default.removeItem(at: outputURL)
                
                self.cleanup()
                return mergedURL
            }
            
            self.cleanup()
            return outputURL
        } else {
            let error = assetWriter.error?.localizedDescription ?? "Unknown error"
            logger.error("❌ Recording failed: \(error)")
            self.cleanup()
            throw RecordingError.writingFailed(error)
        }
    }
    
    /// Cancel recording and delete partial file
    func cancelRecording() {
        guard isRecording else { return }
        
        logger.info("🚫 Cancelling recording...")
        
        isRecording = false
        stopAudioRecording()
        
        if let assetWriter = assetWriter {
            assetWriter.cancelWriting()
            try? FileManager.default.removeItem(at: assetWriter.outputURL)
        }
        
        if let tempAudioURL = tempAudioURL {
            try? FileManager.default.removeItem(at: tempAudioURL)
        }
        
        cleanup()
        logger.info("✅ Recording cancelled")
    }
    
    var recordingInProgress: Bool {
        return isRecording
    }
    
    var recordedFrameCount: Int {
        return frameCount
    }
    
    // MARK: - Private Methods
    
    private func generateOutputURL() -> URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "glasses_video_\(dateFormatter.string(from: Date())).mp4"
        return documentsPath.appendingPathComponent(filename)
    }
    
    private func createPixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        let size = videoSize
        
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }
        
        // Draw image into context
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(origin: .zero, size: size))
        UIGraphicsPopContext()
        
        return buffer
    }
    
    private func startAudioRecording() throws {
        audioEngine = AVAudioEngine()
        
        guard let audioEngine = audioEngine else {
            throw RecordingError.audioSetupFailed
        }
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        // Create temp audio file
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        tempAudioURL = documentsPath.appendingPathComponent("temp_audio_\(dateFormatter.string(from: Date())).caf")
        
        guard let tempAudioURL = tempAudioURL else {
            throw RecordingError.audioSetupFailed
        }
        
        audioFile = try AVAudioFile(forWriting: tempAudioURL, settings: format.settings)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording else { return }
            try? self.audioFile?.write(from: buffer)
        }
        
        try audioEngine.start()
        logger.info("🎤 Audio recording started")
    }
    
    private func stopAudioRecording() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFile = nil
        logger.info("🎤 Audio recording stopped")
    }
    
    private func mergeAudioWithVideo(videoURL: URL, audioURL: URL) async throws -> URL {
        logger.info("🔀 Merging audio with video...")
        
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        
        let composition = AVMutableComposition()
        
        // Add video track
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
              ) else {
            throw RecordingError.mergeFailed
        }
        
        let videoDuration = try await videoAsset.load(.duration)
        try compositionVideoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoDuration),
            of: videoTrack,
            at: .zero
        )
        
        // Add audio track if available
        if let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            let audioDuration = try await audioAsset.load(.duration)
            let insertDuration = min(videoDuration, audioDuration)
            try compositionAudioTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: insertDuration),
                of: audioTrack,
                at: .zero
            )
        }
        
        // Export merged file
        let outputURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(videoURL.deletingPathExtension().lastPathComponent + "_merged.mp4")
        
        // Remove if exists
        try? FileManager.default.removeItem(at: outputURL)
        
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingError.mergeFailed
        }
        
        do {
            try await exporter.export(to: outputURL, as: .mp4)
            logger.info("✅ Audio/video merge completed")
            return outputURL
        } catch {
            logger.error("❌ Merge failed: \(error.localizedDescription)")
            throw RecordingError.mergeFailed
        }
    }
    
    private func cleanup() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        pixelBufferAdaptor = nil
        startTime = nil
        frameCount = 0
        tempAudioURL = nil
    }
}

// MARK: - Recording Error

enum RecordingError: LocalizedError {
    case alreadyRecording
    case notRecording
    case writerNotInitialized
    case writingFailed(String)
    case audioSetupFailed
    case mergeFailed
    
    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress"
        case .notRecording:
            return "No recording in progress"
        case .writerNotInitialized:
            return "Asset writer not initialized"
        case .writingFailed(let reason):
            return "Writing failed: \(reason)"
        case .audioSetupFailed:
            return "Failed to setup audio recording"
        case .mergeFailed:
            return "Failed to merge audio and video"
        }
    }
}
