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

private enum Log {
    nonisolated static let glasses = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "GlassesManager")
}

// MARK: - Media Item

enum MediaItem: Identifiable, Equatable {
    case photo(id: UUID, data: Data, timestamp: Date)
    case video(id: UUID, url: URL, timestamp: Date)
    case audio(id: UUID, url: URL, timestamp: Date)
    
    var id: UUID {
        switch self {
        case .photo(let id, _, _):
            return id
        case .video(let id, _, _):
            return id
        case .audio(let id, _, _):
            return id
        }
    }
    
    var timestamp: Date {
        switch self {
        case .photo(_, _, let timestamp):
            return timestamp
        case .video(_, _, let timestamp):
            return timestamp
        case .audio(_, _, let timestamp):
            return timestamp
        }
    }
    
    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
    
    var isAudio: Bool {
        if case .audio = self { return true }
        return false
    }
}

// MARK: - Stored Media Item (for persistence)

private struct StoredMediaItem: Codable {
    let id: UUID
    let type: MediaType
    let timestamp: Date
    let photoData: Data?
    let filePath: String?
    
    enum MediaType: String, Codable {
        case photo
        case video
        case audio
    }
    
    init(from mediaItem: MediaItem) {
        self.id = mediaItem.id
        self.timestamp = mediaItem.timestamp
        switch mediaItem {
        case .photo(_, let data, _):
            self.type = .photo
            self.photoData = data
            self.filePath = nil
        case .video(_, let url, _):
            self.type = .video
            self.photoData = nil
            self.filePath = url.path
        case .audio(_, let url, _):
            self.type = .audio
            self.photoData = nil
            self.filePath = url.path
        }
    }
    
    func toMediaItem() -> MediaItem? {
        switch type {
        case .photo:
            guard let data = photoData else {
                Log.glasses.warning("⚠️ Photo data missing for item \(id)")
                return nil
            }
            return .photo(id: id, data: data, timestamp: timestamp)
        case .video:
            guard let path = filePath else {
                Log.glasses.warning("⚠️ Video path missing for item \(id)")
                return nil
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Log.glasses.warning("⚠️ Video file not found: \(path) - user may have deleted it")
                return nil
            }
            return .video(id: id, url: url, timestamp: timestamp)
        case .audio:
            guard let path = filePath else {
                Log.glasses.warning("⚠️ Audio path missing for item \(id)")
                return nil
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Log.glasses.warning("⚠️ Audio file not found: \(path) - user may have deleted it")
                return nil
            }
            return .audio(id: id, url: url, timestamp: timestamp)
        }
    }
}

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
                Log.glasses.info("🔄 State changed: \(oldValue.displayText) → \(self.connectionState.displayText)")
            }
        }
    }
    @Published private(set) var availableDevices: [DeviceIdentifier] = []
    @Published private(set) var currentFrame: VideoFrame?
    @Published private(set) var capturedMedia: [MediaItem] = []
    @Published private(set) var isRegistered: Bool = false
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var isAudioConfigured: Bool = false
    @Published private(set) var audioRecordingState: AudioRecordingState = .idle
    @Published private(set) var currentAudioInput: String = "No input"
    
    // MARK: - Private Properties
    
    private let wearables: WearablesInterface
    private var deviceSelector: AutoDeviceSelector?
    private var streamSession: StreamSession?
    
    // Audio and video recording
    private let audioManager = AudioManager()
    private let videoRecorder = VideoRecorder()
    private var pendingRecordingURL: URL?
    
    // Media persistence
    private static let mediaStorageURL: URL = {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent("captured_media.json")
    }()
    
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
        Log.glasses.info("📱 GlassesManager initialized")
        self.wearables = Wearables.shared
        loadMediaList()
        setupDevicesListener()
        setupRegistrationListener()
    }
    
    // MARK: - Public Methods
    
    func register() {
        if isRegistered {
            Log.glasses.info("📝 Already registered, skipping")
            return
        }
        
        Task {
            // Check current registration state from stream before attempting
            for await state in wearables.registrationStateStream() {
                if case .registered = state {
                    Log.glasses.info("📝 Already registered (confirmed from stream), skipping")
                    await MainActor.run { self.isRegistered = true }
                    return
                }
                // Got first state, it's not registered - proceed
                break
            }
            
            Log.glasses.info("📝 Starting registration with Meta AI app...")
            do {
                try wearables.startRegistration()
                Log.glasses.info("✅ Registration started - check Meta AI app")
            } catch {
                Log.glasses.warning("⚠️ Registration request failed: \(error.localizedDescription)")
            }
        }
    }
    
    func unregister() {
        Log.glasses.info("📝 Starting unregistration...")
        do {
            try wearables.startUnregistration()
            Log.glasses.info("✅ Unregistration started")
        } catch {
            Log.glasses.error("❌ Unregistration failed: \(error.localizedDescription)")
        }
    }
    
    func startSearching() {
        Log.glasses.info("🔍 Starting device search")
        connectionState = .searching
        deviceSelector = AutoDeviceSelector(wearables: wearables)
        
        Task {
            for await device in deviceSelector!.activeDeviceStream() {
                if let device = device {
                    Log.glasses.info("✅ Device found: \(String(describing: device))")
                    connectionState = .connected
                    break
                }
            }
        }
    }
    
    func stopSearching() {
        Log.glasses.info("⏹️ Stopping device search")
        deviceSelector = nil
        connectionState = .disconnected
    }
    
    func startStreaming() {
        Log.glasses.info("🎬 Starting streaming...")
        guard let selector = deviceSelector else {
            Log.glasses.error("❌ No device selector available")
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
                Log.glasses.info("🎤 Audio configured, HFP ready")
            } catch {
                Log.glasses.warning("⚠️ Audio configuration failed: \(error.localizedDescription)")
                isAudioConfigured = false
                // Continue without audio - video streaming still works
            }
            
            // Check and request camera permission
            do {
                let cameraStatus = try await wearables.checkPermissionStatus(.camera)
                
                if cameraStatus != .granted {
                    Log.glasses.info("📷 Requesting camera permission...")
                    let newStatus = try await wearables.requestPermission(.camera)
                    
                    if newStatus != .granted {
                        Log.glasses.error("❌ Camera permission denied")
                        connectionState = .error("Camera permission denied")
                        return
                    }
                    Log.glasses.info("📷 Camera permission granted")
                }
            } catch {
                Log.glasses.error("❌ Camera permission error: \(error.localizedDescription)")
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
        Log.glasses.info("⏹️ Stopping streaming")
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
            Log.glasses.warning("⚠️ Must be streaming to record")
            recordingState = .error("Must be streaming to record")
            return
        }
        
        guard recordingState == .idle else {
            Log.glasses.warning("⚠️ Recording already in progress")
            return
        }
        
        // Get video size from current frame, default to high resolution (720x1280 portrait)
        var videoSize = CGSize(width: 720, height: 1280) // Default high resolution (portrait)
        if let frame = currentFrame, let image = frame.makeUIImage() {
            videoSize = image.size
        }
        
        do {
            pendingRecordingURL = try videoRecorder.startRecording(
                videoSize: videoSize,
                frameRate: 30
            )
            recordingState = .recording
            Log.glasses.info("🔴 Recording started")
        } catch {
            Log.glasses.error("❌ Failed to start recording: \(error.localizedDescription)")
            recordingState = .error(error.localizedDescription)
        }
    }
    
    func stopRecording() {
        guard recordingState == .recording else {
            Log.glasses.warning("⚠️ No recording in progress")
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
                let mediaItem = MediaItem.video(id: UUID(), url: outputURL, timestamp: Date())
                self.capturedMedia.insert(mediaItem, at: 0)
                self.saveMediaList()
                self.recordingState = .idle
            }
            Log.glasses.info("✅ Recording saved: \(outputURL.lastPathComponent)")
        } catch {
            await MainActor.run {
                self.recordingState = .error(error.localizedDescription)
            }
            Log.glasses.error("❌ Failed to stop recording: \(error.localizedDescription)")
        }
    }
    
    func cancelRecording() {
        guard recordingState == .recording else { return }
        
        videoRecorder.cancelRecording()
        recordingState = .idle
        pendingRecordingURL = nil
    }
    
    // MARK: - Audio Recording (Bluetooth HFP - no DAT required)
    
    /// Start audio recording from Bluetooth microphone (glasses)
    /// This uses standard iOS Bluetooth audio, not DAT SDK
    func startAudioRecording() {
        guard audioRecordingState == .idle else {
            Log.glasses.warning("⚠️ Audio recording already in progress")
            return
        }
        
        do {
            _ = try audioManager.startRecording()
            audioRecordingState = .recording
            currentAudioInput = audioManager.getCurrentInputDescription()
            Log.glasses.info("🎙️ Audio recording started from: \(self.currentAudioInput)")
        } catch {
            Log.glasses.error("❌ Failed to start audio recording: \(error.localizedDescription)")
            audioRecordingState = .error(error.localizedDescription)
        }
    }
    
    /// Stop audio recording and save to media library
    func stopAudioRecording() {
        guard audioRecordingState == .recording else {
            Log.glasses.warning("⚠️ No audio recording in progress")
            return
        }
        
        audioRecordingState = .finishing
        
        do {
            let outputURL = try audioManager.stopRecording()
            let mediaItem = MediaItem.audio(id: UUID(), url: outputURL, timestamp: Date())
            capturedMedia.insert(mediaItem, at: 0)
            saveMediaList()
            audioRecordingState = .idle
            Log.glasses.info("✅ Audio recording saved: \(outputURL.lastPathComponent)")
        } catch {
            Log.glasses.error("❌ Failed to stop audio recording: \(error.localizedDescription)")
            audioRecordingState = .error(error.localizedDescription)
        }
    }
    
    /// Cancel audio recording without saving
    func cancelAudioRecording() {
        guard audioRecordingState == .recording else { return }
        
        audioManager.cancelRecording()
        audioRecordingState = .idle
        Log.glasses.info("🗑️ Audio recording cancelled")
    }
    
    /// Check if Bluetooth microphone (glasses) is available
    func checkBluetoothAudioAvailable() -> Bool {
        return audioManager.isBluetoothInputAvailable()
    }
    
    /// Refresh current audio input info
    func refreshAudioInputInfo() {
        currentAudioInput = audioManager.getCurrentInputDescription()
    }
    
    func capturePhoto() {
        Log.glasses.info("📸 Capturing photo...")
        if streamSession != nil {
            streamSession?.capturePhoto(format: .jpeg)
        } else {
            // Start a temporary stream session just for photo capture
            capturePhotoWithTemporaryStream()
        }
    }
    
    private func capturePhotoWithTemporaryStream() {
        guard let selector = deviceSelector else {
            Log.glasses.error("❌ No device selector for photo capture")
            connectionState = .error("Connect to glasses first")
            return
        }
        
        Task {
            // Check camera permission
            do {
                let cameraStatus = try await wearables.checkPermissionStatus(.camera)
                if cameraStatus != .granted {
                    Log.glasses.info("📷 Requesting camera permission for photo...")
                    let newStatus = try await wearables.requestPermission(.camera)
                    if newStatus != .granted {
                        Log.glasses.error("❌ Camera permission denied")
                        connectionState = .error("Camera permission denied")
                        return
                    }
                }
            } catch {
                Log.glasses.error("❌ Camera permission error: \(error.localizedDescription)")
                return
            }
            
            Log.glasses.info("📸 Starting temporary stream for photo capture")
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
                Log.glasses.info("📸 Photo received: \(photoData.data.count) bytes")
                self.savePhotoToLibrary(imageData: photoData.data)
                Task { @MainActor in
                    let mediaItem = MediaItem.photo(id: UUID(), data: photoData.data, timestamp: Date())
                    self.capturedMedia.insert(mediaItem, at: 0)
                    self.saveMediaList()
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
            Log.glasses.info("📸 Temporary stream stopped")
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
            Log.glasses.warning("⚠️ No recording in progress")
            return
        }
        
        Task {
            await stopRecordingInternal()
            
            // If we started stream just for this video, stop it
            if isQuickVideoMode {
                isQuickVideoMode = false
                Log.glasses.info("📹 Quick video mode - stopping temporary stream")
                stopStreaming()
            }
        }
    }
    
    private func startVideoWithTemporaryStream() {
        guard let selector = deviceSelector else {
            Log.glasses.error("❌ No device selector for video capture")
            connectionState = .error("Connect to glasses first")
            return
        }
        
        isQuickVideoMode = true
        
        Task {
            // Check camera permission
            do {
                let cameraStatus = try await wearables.checkPermissionStatus(.camera)
                if cameraStatus != .granted {
                    Log.glasses.info("📷 Requesting camera permission for video...")
                    let newStatus = try await wearables.requestPermission(.camera)
                    if newStatus != .granted {
                        Log.glasses.error("❌ Camera permission denied")
                        connectionState = .error("Camera permission denied")
                        isQuickVideoMode = false
                        return
                    }
                }
            } catch {
                Log.glasses.error("❌ Camera permission error: \(error.localizedDescription)")
                isQuickVideoMode = false
                return
            }
            
            // Configure audio BEFORE starting stream
            do {
                try audioManager.configureForHFP()
                isAudioConfigured = true
                try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                Log.glasses.info("🎤 Audio configured for quick video")
            } catch {
                Log.glasses.warning("⚠️ Audio configuration failed: \(error.localizedDescription)")
                isAudioConfigured = false
            }
            
            Log.glasses.info("📹 Starting temporary stream for video recording")
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
                Log.glasses.error("❌ Failed to start streaming for video")
                isQuickVideoMode = false
            }
        }
    }
    
    func disconnect() {
        Log.glasses.info("🔌 Disconnecting...")
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
            Log.glasses.info("✅ Disconnected")
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDevicesListener() {
        devicesListenerToken = wearables.addDevicesListener { [weak self] devices in
            guard let self else { return }
            Task { @MainActor in
                if devices.count != self.availableDevices.count {
                    Log.glasses.info("📱 Devices: \(devices.count) available")
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
                            Log.glasses.info("✅ App is registered with Meta AI")
                        }
                    } else {
                        self.isRegistered = false
                        if wasRegistered {
                            Log.glasses.info("⚪ App unregistered: \(String(describing: state))")
                        }
                    }
                }
            }
        }
    }
    
    // Track frame count for logging (not every frame) - must be actor-isolated
    private var streamFrameCount: Int = 0
    
    private func subscribeToStreamSession() {
        guard let session = streamSession else { return }
        
        // Reset frame count for new stream session
        streamFrameCount = 0
        
        // Subscribe to video frames
        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] (frame: VideoFrame) in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                // Append frame to video recorder if recording
                if self.videoRecorder.recordingInProgress {
                    if let image = frame.makeUIImage() {
                        self.videoRecorder.appendFrame(image: image)
                    }
                }
                
                self.streamFrameCount += 1
                // Log every 100th frame to avoid spam
                if self.streamFrameCount == 1 || self.streamFrameCount % 100 == 0 {
                    Log.glasses.debug("🎞️ Frame #\(self.streamFrameCount) received")
                }
                self.currentFrame = frame
            }
        }
        
        // Subscribe to photos
        photoListenerToken = session.photoDataPublisher.listen { [weak self] (photoData: PhotoData) in
            guard let self else { return }
            Log.glasses.info("📸 Photo received: \(photoData.data.count) bytes")
            self.savePhotoToLibrary(imageData: photoData.data)
            Task { @MainActor in
                let mediaItem = MediaItem.photo(id: UUID(), data: photoData.data, timestamp: Date())
                self.capturedMedia.insert(mediaItem, at: 0)
                self.saveMediaList()
            }
        }
        
        // Subscribe to errors
        errorListenerToken = session.errorPublisher.listen { [weak self] (error: StreamSessionError) in
            guard let self else { return }
            Log.glasses.error("❌ Stream error: \(error.localizedDescription)")
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
            Log.glasses.info("🟢 Streaming started")
            connectionState = .streaming
        case .starting:
            connectionState = .connecting
        case .stopping:
            connectionState = .connecting
        case .paused:
            connectionState = .connected
        @unknown default:
            Log.glasses.warning("⚠️ Unknown stream state: \(String(describing: state))")
        }
    }
    
    // MARK: - Photo Library Saving
    
    /// Save photo to Photo Library. Can be called from any context.
    nonisolated private func savePhotoToLibrary(imageData: Data) {
        Task.detached(priority: .utility) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Log.glasses.warning("⚠️ Photo library access denied")
                return
            }
            
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    creationRequest.addResource(with: .photo, data: imageData, options: nil)
                }
                Log.glasses.info("✅ Photo saved to library")
            } catch {
                Log.glasses.error("❌ Failed to save photo: \(error.localizedDescription)")
            }
        }
    }
    
    /// Save video to Photo Library. Can be called from any context.
    nonisolated private func saveVideoToLibrary(videoURL: URL) {
        Task.detached(priority: .utility) {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                Log.glasses.warning("⚠️ Photo library access denied")
                return
            }
            
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                }
                Log.glasses.info("✅ Video saved to library")
            } catch {
                Log.glasses.error("❌ Failed to save video: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Media Persistence
    
    private func saveMediaList() {
        let storedItems = capturedMedia.map { StoredMediaItem(from: $0) }
        do {
            let data = try JSONEncoder().encode(storedItems)
            try data.write(to: Self.mediaStorageURL)
            Log.glasses.info("💾 Saved \(storedItems.count) media items")
        } catch {
            Log.glasses.error("❌ Failed to save media list: \(error.localizedDescription)")
        }
    }
    
    private func loadMediaList() {
        guard FileManager.default.fileExists(atPath: Self.mediaStorageURL.path) else {
            Log.glasses.info("📂 No saved media list found")
            return
        }
        
        do {
            let data = try Data(contentsOf: Self.mediaStorageURL)
            let storedItems = try JSONDecoder().decode([StoredMediaItem].self, from: data)
            let loadedItems = storedItems.compactMap { $0.toMediaItem() }
            let skippedCount = storedItems.count - loadedItems.count
            
            capturedMedia = loadedItems
            Log.glasses.info("📂 Loaded \(loadedItems.count) media items")
            
            // Clean up metadata for missing files - they can't be recovered
            if skippedCount > 0 {
                Log.glasses.info("🧹 Removing \(skippedCount) orphaned metadata entries (files not found)")
                saveMediaList()
            }
        } catch {
            Log.glasses.error("❌ Failed to load media list: \(error.localizedDescription)")
        }
    }
}
