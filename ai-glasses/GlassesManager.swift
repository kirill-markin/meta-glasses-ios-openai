//
//  GlassesManager.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera
import AVFoundation
import Photos
import os.log

// MARK: - Logging

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "GlassesManager")

// MARK: - Connection State

enum GlassesConnectionState: Equatable {
    case disconnected
    case searching
    case connecting
    case connected
    case streaming
    case error(String)
    
    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .searching:
            return "Searching..."
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .streaming:
            return "Streaming"
        case .error(let message):
            return "Error: \(message)"
        }
    }
    
    var isConnected: Bool {
        switch self {
        case .connected, .streaming:
            return true
        default:
            return false
        }
    }
}

// MARK: - Glasses Manager

@MainActor
final class GlassesManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var connectionState: GlassesConnectionState = .disconnected {
        didSet {
            if oldValue != connectionState {
                logger.info("🔄 State changed: \(oldValue.displayText) → \(self.connectionState.displayText)")
            }
        }
    }
    @Published private(set) var availableDevices: [DeviceIdentifier] = []
    @Published private(set) var currentFrame: VideoFrame?
    @Published private(set) var lastCapturedPhoto: Data?
    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var lastRecordedVideoURL: URL?
    @Published private(set) var isAudioConfigured: Bool = false
    
    // MARK: - Private Properties
    
    private let wearables: WearablesInterface
    private var deviceSelector: AutoDeviceSelector?
    private var streamSession: StreamSession?
    
    // Audio and video recording
    private let audioManager = AudioManager()
    private let videoRecorder = VideoRecorder()
    private var pendingRecordingURL: URL?
    
    // Quick video mode - started stream just for video capture
    private var isQuickVideoMode: Bool = false
    
    // Listener tokens - must be retained to keep subscriptions active
    private var devicesListenerToken: AnyListenerToken?
    private var videoFrameListenerToken: AnyListenerToken?
    private var photoListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private var stateListenerToken: AnyListenerToken?
    
    // MARK: - Initialization
    
    init() {
        logger.info("📱 GlassesManager initialized")
        self.wearables = Wearables.shared
        setupDevicesListener()
        setupRegistrationListener()
    }
    
    // MARK: - Public Methods
    
    func register() {
        if isRegistered {
            logger.info("📝 Already registered, skipping")
            return
        }
        
        Task {
            // Check current registration state from stream before attempting
            for await state in wearables.registrationStateStream() {
                if case .registered = state {
                    logger.info("📝 Already registered (confirmed from stream), skipping")
                    await MainActor.run { self.isRegistered = true }
                    return
                }
                // Got first state, it's not registered - proceed
                break
            }
            
            logger.info("📝 Starting registration with Meta AI app...")
            do {
                try wearables.startRegistration()
                logger.info("✅ Registration started - check Meta AI app")
            } catch {
                logger.warning("⚠️ Registration request failed: \(error.localizedDescription)")
            }
        }
    }
    
    func unregister() {
        logger.info("📝 Starting unregistration...")
        do {
            try wearables.startUnregistration()
            logger.info("✅ Unregistration started")
        } catch {
            logger.error("❌ Unregistration failed: \(error.localizedDescription)")
        }
    }
    
    func startSearching() {
        logger.info("🔍 Starting device search")
        connectionState = .searching
        deviceSelector = AutoDeviceSelector(wearables: wearables)
        
        Task {
            for await device in deviceSelector!.activeDeviceStream() {
                if let device = device {
                    logger.info("✅ Device found: \(String(describing: device))")
                    connectionState = .connected
                    break
                }
            }
        }
    }
    
    func stopSearching() {
        logger.info("⏹️ Stopping device search")
        deviceSelector = nil
        connectionState = .disconnected
    }
    
    func startStreaming() {
        logger.info("🎬 Starting streaming...")
        guard let selector = deviceSelector else {
            logger.error("❌ No device selector available")
            connectionState = .error("No device selector available")
            return
        }
        
        Task {
            // Configure audio BEFORE starting stream (required for HFP)
            do {
                try audioManager.configureForHFP()
                isAudioConfigured = true
                
                // Wait for HFP to be ready (as per Meta docs)
                try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                logger.info("🎤 Audio configured, HFP ready")
            } catch {
                logger.warning("⚠️ Audio configuration failed: \(error.localizedDescription)")
                isAudioConfigured = false
                // Continue without audio - video streaming still works
            }
            
            // Check and request camera permission
            do {
                let cameraStatus = try await wearables.checkPermissionStatus(.camera)
                
                if cameraStatus != .granted {
                    logger.info("📷 Requesting camera permission...")
                    let newStatus = try await wearables.requestPermission(.camera)
                    
                    if newStatus != .granted {
                        logger.error("❌ Camera permission denied")
                        connectionState = .error("Camera permission denied")
                        return
                    }
                    logger.info("📷 Camera permission granted")
                }
            } catch {
                logger.error("❌ Camera permission error: \(error.localizedDescription)")
                connectionState = .error("Camera permission error: \(error.localizedDescription)")
                return
            }
            
            // Maximum quality: high resolution (720x1280), 30 FPS
            let config = StreamSessionConfig(
                videoCodec: .raw,
                resolution: .high,
                frameRate: 30
            )
            
            streamSession = StreamSession(
                streamSessionConfig: config,
                deviceSelector: selector
            )
            
            subscribeToStreamSession()
            await streamSession?.start()
        }
    }
    
    func stopStreaming() {
        logger.info("⏹️ Stopping streaming")
        Task {
            // Stop recording if in progress
            if recordingState == .recording {
                await stopRecordingInternal()
            }
            
            await streamSession?.stop()
            streamSession = nil
            currentFrame = nil
            await cancelStreamListeners()
            
            // Deactivate audio
            audioManager.deactivate()
            isAudioConfigured = false
            
            if deviceSelector?.activeDevice != nil {
                connectionState = .connected
            } else {
                connectionState = .disconnected
            }
        }
    }
    
    // MARK: - Video Recording
    
    func startRecording() {
        guard connectionState == .streaming else {
            logger.warning("⚠️ Must be streaming to record")
            recordingState = .error("Must be streaming to record")
            return
        }
        
        guard recordingState == .idle else {
            logger.warning("⚠️ Recording already in progress")
            return
        }
        
        // Get video size from current frame, default to high resolution (720x1280)
        var videoSize = CGSize(width: 1280, height: 720) // Default high resolution
        if let frame = currentFrame, let image = frame.makeUIImage() {
            videoSize = image.size
        }
        
        do {
            pendingRecordingURL = try videoRecorder.startRecording(
                videoSize: videoSize,
                frameRate: 30
            )
            recordingState = .recording
            logger.info("🔴 Recording started")
        } catch {
            logger.error("❌ Failed to start recording: \(error.localizedDescription)")
            recordingState = .error(error.localizedDescription)
        }
    }
    
    func stopRecording() {
        guard recordingState == .recording else {
            logger.warning("⚠️ No recording in progress")
            return
        }
        
        Task {
            await stopRecordingInternal()
        }
    }
    
    private func stopRecordingInternal() async {
        recordingState = .finishing
        
        do {
            let outputURL = try await videoRecorder.stopRecording()
            saveVideoToLibrary(videoURL: outputURL)
            await MainActor.run {
                self.lastRecordedVideoURL = outputURL
                self.recordingState = .idle
            }
            logger.info("✅ Recording saved: \(outputURL.lastPathComponent)")
        } catch {
            await MainActor.run {
                self.recordingState = .error(error.localizedDescription)
            }
            logger.error("❌ Failed to stop recording: \(error.localizedDescription)")
        }
    }
    
    func cancelRecording() {
        guard recordingState == .recording else { return }
        
        videoRecorder.cancelRecording()
        recordingState = .idle
        pendingRecordingURL = nil
    }
    
    func capturePhoto() {
        logger.info("📸 Capturing photo...")
        if streamSession != nil {
            streamSession?.capturePhoto(format: .jpeg)
        } else {
            // Start a temporary stream session just for photo capture
            capturePhotoWithTemporaryStream()
        }
    }
    
    private func capturePhotoWithTemporaryStream() {
        guard let selector = deviceSelector else {
            logger.error("❌ No device selector for photo capture")
            connectionState = .error("Connect to glasses first")
            return
        }
        
        Task {
            // Check camera permission
            do {
                let cameraStatus = try await wearables.checkPermissionStatus(.camera)
                if cameraStatus != .granted {
                    logger.info("📷 Requesting camera permission for photo...")
                    let newStatus = try await wearables.requestPermission(.camera)
                    if newStatus != .granted {
                        logger.error("❌ Camera permission denied")
                        connectionState = .error("Camera permission denied")
                        return
                    }
                }
            } catch {
                logger.error("❌ Camera permission error: \(error.localizedDescription)")
                return
            }
            
            logger.info("📸 Starting temporary stream for photo capture")
            // Maximum quality for photo: high resolution (720x1280)
            let config = StreamSessionConfig(
                videoCodec: .raw,
                resolution: .high,
                frameRate: 30
            )
            let tempSession = StreamSession(streamSessionConfig: config, deviceSelector: selector)
            
            // Subscribe to photo only
            let photoToken = tempSession.photoDataPublisher.listen { [weak self] (photoData: PhotoData) in
                guard let self else { return }
                logger.info("📸 Photo received: \(photoData.data.count) bytes")
                self.savePhotoToLibrary(imageData: photoData.data)
                Task { @MainActor in
                    self.lastCapturedPhoto = photoData.data
                }
            }
            
            await tempSession.start()
            
            // Small delay to ensure stream is ready
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec
            
            tempSession.capturePhoto(format: .jpeg)
            
            // Wait for photo to be captured
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 sec
            
            await tempSession.stop()
            await photoToken.cancel()
            logger.info("📸 Temporary stream stopped")
        }
    }
    
    // MARK: - Quick Video Recording (with temporary stream)
    
    /// Start video recording - will start stream if not already streaming
    func startQuickVideoRecording() {
        if connectionState == .streaming {
            // Already streaming - just start recording
            startRecording()
        } else {
            // Need to start stream first
            startVideoWithTemporaryStream()
        }
    }
    
    /// Stop video recording - will stop stream if we started it for this recording
    func stopQuickVideoRecording() {
        guard recordingState == .recording else {
            logger.warning("⚠️ No recording in progress")
            return
        }
        
        Task {
            await stopRecordingInternal()
            
            // If we started stream just for this video, stop it
            if isQuickVideoMode {
                isQuickVideoMode = false
                logger.info("📹 Quick video mode - stopping temporary stream")
                stopStreaming()
            }
        }
    }
    
    private func startVideoWithTemporaryStream() {
        guard let selector = deviceSelector else {
            logger.error("❌ No device selector for video capture")
            connectionState = .error("Connect to glasses first")
            return
        }
        
        isQuickVideoMode = true
        
        Task {
            // Check camera permission
            do {
                let cameraStatus = try await wearables.checkPermissionStatus(.camera)
                if cameraStatus != .granted {
                    logger.info("📷 Requesting camera permission for video...")
                    let newStatus = try await wearables.requestPermission(.camera)
                    if newStatus != .granted {
                        logger.error("❌ Camera permission denied")
                        connectionState = .error("Camera permission denied")
                        isQuickVideoMode = false
                        return
                    }
                }
            } catch {
                logger.error("❌ Camera permission error: \(error.localizedDescription)")
                isQuickVideoMode = false
                return
            }
            
            // Configure audio BEFORE starting stream
            do {
                try audioManager.configureForHFP()
                isAudioConfigured = true
                try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                logger.info("🎤 Audio configured for quick video")
            } catch {
                logger.warning("⚠️ Audio configuration failed: \(error.localizedDescription)")
                isAudioConfigured = false
            }
            
            logger.info("📹 Starting temporary stream for video recording")
            // Maximum quality for video: high resolution (720x1280), 30 FPS
            let config = StreamSessionConfig(
                videoCodec: .raw,
                resolution: .high,
                frameRate: 30
            )
            streamSession = StreamSession(streamSessionConfig: config, deviceSelector: selector)
            
            subscribeToStreamSession()
            await streamSession?.start()
            
            // Wait for streaming state before starting recording
            // Poll for streaming state with timeout
            var attempts = 0
            while connectionState != .streaming && attempts < 20 {
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25 sec
                attempts += 1
            }
            
            if connectionState == .streaming {
                // Small extra delay to ensure stable stream
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 sec
                startRecording()
            } else {
                logger.error("❌ Failed to start streaming for video")
                isQuickVideoMode = false
            }
        }
    }
    
    func disconnect() {
        logger.info("🔌 Disconnecting...")
        Task {
            // Cancel any recording in progress
            if recordingState == .recording {
                videoRecorder.cancelRecording()
                recordingState = .idle
            }
            
            await streamSession?.stop()
            streamSession = nil
            currentFrame = nil
            await cancelStreamListeners()
            
            // Deactivate audio
            audioManager.deactivate()
            isAudioConfigured = false
            
            isQuickVideoMode = false
            deviceSelector = nil
            connectionState = .disconnected
            logger.info("✅ Disconnected")
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDevicesListener() {
        devicesListenerToken = wearables.addDevicesListener { [weak self] devices in
            guard let self else { return }
            Task { @MainActor in
                if devices.count != self.availableDevices.count {
                    logger.info("📱 Devices: \(devices.count) available")
                }
                self.availableDevices = devices
            }
        }
    }
    
    private func setupRegistrationListener() {
        Task {
            for await state in wearables.registrationStateStream() {
                await MainActor.run {
                    let wasRegistered = self.isRegistered
                    // Check if state is .registered
                    if case .registered = state {
                        self.isRegistered = true
                        if !wasRegistered {
                            logger.info("✅ App is registered with Meta AI")
                        }
                    } else {
                        self.isRegistered = false
                        if wasRegistered {
                            logger.info("⚪ App unregistered: \(String(describing: state))")
                        }
                    }
                }
            }
        }
    }
    
    private func subscribeToStreamSession() {
        guard let session = streamSession else { return }
        
        // Track frame count for logging (not every frame)
        var frameCount = 0
        
        // Subscribe to video frames
        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] (frame: VideoFrame) in
            guard let self else { return }
            frameCount += 1
            // Log every 100th frame to avoid spam
            if frameCount == 1 || frameCount % 100 == 0 {
                logger.debug("🎞️ Frame #\(frameCount) received")
            }
            
            // Append frame to video recorder if recording
            if self.videoRecorder.recordingInProgress {
                if let image = frame.makeUIImage() {
                    self.videoRecorder.appendFrame(image: image)
                }
            }
            
            Task { @MainActor in
                self.currentFrame = frame
            }
        }
        
        // Subscribe to photos
        photoListenerToken = session.photoDataPublisher.listen { [weak self] (photoData: PhotoData) in
            guard let self else { return }
            logger.info("📸 Photo received: \(photoData.data.count) bytes")
            self.savePhotoToLibrary(imageData: photoData.data)
            Task { @MainActor in
                self.lastCapturedPhoto = photoData.data
            }
        }
        
        // Subscribe to errors
        errorListenerToken = session.errorPublisher.listen { [weak self] (error: StreamSessionError) in
            guard let self else { return }
            logger.error("❌ Stream error: \(error.localizedDescription)")
            Task { @MainActor in
                self.connectionState = .error(error.localizedDescription)
            }
        }
        
        // Subscribe to state changes
        stateListenerToken = session.statePublisher.listen { [weak self] (state: StreamSessionState) in
            guard let self else { return }
            Task { @MainActor in
                self.handleStreamState(state)
            }
        }
    }
    
    private func cancelStreamListeners() async {
        await videoFrameListenerToken?.cancel()
        await photoListenerToken?.cancel()
        await errorListenerToken?.cancel()
        await stateListenerToken?.cancel()
        
        videoFrameListenerToken = nil
        photoListenerToken = nil
        errorListenerToken = nil
        stateListenerToken = nil
    }
    
    private func handleStreamState(_ state: StreamSessionState) {
        switch state {
        case .stopped:
            if deviceSelector?.activeDevice != nil {
                connectionState = .connected
            } else {
                connectionState = .disconnected
            }
        case .waitingForDevice:
            connectionState = .searching
        case .streaming:
            logger.info("🟢 Streaming started")
            connectionState = .streaming
        case .starting:
            connectionState = .connecting
        case .stopping:
            connectionState = .connecting
        case .paused:
            connectionState = .connected
        @unknown default:
            logger.warning("⚠️ Unknown stream state: \(String(describing: state))")
        }
    }
    
    // MARK: - Photo Library Saving
    
    private func savePhotoToLibrary(imageData: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                logger.warning("⚠️ Photo library access denied")
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.addResource(with: .photo, data: imageData, options: nil)
            } completionHandler: { success, error in
                if success {
                    logger.info("✅ Photo saved to library")
                } else if let error = error {
                    logger.error("❌ Failed to save photo: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func saveVideoToLibrary(videoURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                logger.warning("⚠️ Photo library access denied")
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            } completionHandler: { success, error in
                if success {
                    logger.info("✅ Video saved to library")
                } else if let error = error {
                    logger.error("❌ Failed to save video: \(error.localizedDescription)")
                }
            }
        }
    }
}
