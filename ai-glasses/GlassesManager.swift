//
//  GlassesManager.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import Foundation
import Combine
import MWDATCore
import MWDATCamera
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
            logger.info("🔄 State changed: \(oldValue.displayText) → \(self.connectionState.displayText)")
        }
    }
    @Published private(set) var availableDevices: [DeviceIdentifier] = []
    @Published private(set) var currentFrame: VideoFrame?
    @Published private(set) var lastCapturedPhoto: Data?
    
    // MARK: - Private Properties
    
    private let wearables: WearablesInterface
    private var deviceSelector: AutoDeviceSelector?
    private var streamSession: StreamSession?
    
    // Listener tokens - must be retained to keep subscriptions active
    private var devicesListenerToken: AnyListenerToken?
    private var videoFrameListenerToken: AnyListenerToken?
    private var photoListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private var stateListenerToken: AnyListenerToken?
    
    // MARK: - Initialization
    
    init() {
        logger.info("📱 GlassesManager initializing...")
        self.wearables = Wearables.shared
        setupDevicesListener()
        logger.info("✅ GlassesManager initialized")
    }
    
    // MARK: - Public Methods
    
    func startSearching() {
        logger.info("🔍 Starting device search...")
        connectionState = .searching
        deviceSelector = AutoDeviceSelector(wearables: wearables)
        
        Task {
            logger.info("🔍 Waiting for active device stream...")
            for await device in deviceSelector!.activeDeviceStream() {
                if let device = device {
                    logger.info("✅ Device found: \(String(describing: device))")
                    connectionState = .connected
                    break
                } else {
                    logger.info("⏳ Device stream yielded nil, continuing search...")
                }
            }
            logger.info("🔍 Device stream ended")
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
        
        // Use default config: raw video, medium resolution, 30 FPS
        let config = StreamSessionConfig()
        logger.info("📹 Creating StreamSession with default config")
        
        streamSession = StreamSession(
            streamSessionConfig: config,
            deviceSelector: selector
        )
        
        subscribeToStreamSession()
        logger.info("📡 Subscribed to stream session publishers")
        
        Task {
            logger.info("▶️ Calling streamSession.start()...")
            await streamSession?.start()
            logger.info("✅ streamSession.start() completed")
            connectionState = .streaming
        }
    }
    
    func stopStreaming() {
        logger.info("⏹️ Stopping streaming...")
        Task {
            await streamSession?.stop()
            logger.info("⏹️ Stream stopped")
            streamSession = nil
            currentFrame = nil
            await cancelStreamListeners()
            
            if deviceSelector?.activeDevice != nil {
                logger.info("📱 Device still active, setting state to connected")
                connectionState = .connected
            } else {
                logger.info("📱 No active device, setting state to disconnected")
                connectionState = .disconnected
            }
        }
    }
    
    func capturePhoto() {
        logger.info("📸 Capturing photo...")
        streamSession?.capturePhoto(format: .jpeg)
    }
    
    func disconnect() {
        logger.info("🔌 Disconnecting...")
        Task {
            await streamSession?.stop()
            streamSession = nil
            currentFrame = nil
            await cancelStreamListeners()
            deviceSelector = nil
            connectionState = .disconnected
            logger.info("✅ Disconnected")
        }
    }
    
    // MARK: - Private Methods
    
    private func setupDevicesListener() {
        logger.info("👂 Setting up devices listener...")
        devicesListenerToken = wearables.addDevicesListener { [weak self] devices in
            guard let self else { return }
            Task { @MainActor in
                logger.info("📱 Devices updated: \(devices.count) device(s) available")
                for (index, device) in devices.enumerated() {
                    logger.info("  📱 Device \(index): \(String(describing: device))")
                }
                self.availableDevices = devices
            }
        }
    }
    
    private func subscribeToStreamSession() {
        guard let session = streamSession else {
            logger.warning("⚠️ No stream session to subscribe to")
            return
        }
        
        // Track frame count for logging (not every frame)
        var frameCount = 0
        
        // Subscribe to video frames
        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] (frame: VideoFrame) in
            guard let self else { return }
            frameCount += 1
            // Log every 30th frame to avoid spam
            if frameCount % 30 == 1 {
                logger.debug("🎞️ Frame #\(frameCount) received")
            }
            Task { @MainActor in
                self.currentFrame = frame
            }
        }
        
        // Subscribe to photos
        photoListenerToken = session.photoDataPublisher.listen { [weak self] (photoData: PhotoData) in
            guard let self else { return }
            logger.info("📸 Photo received: \(photoData.data.count) bytes")
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
            logger.info("📺 Stream state changed: \(String(describing: state))")
            Task { @MainActor in
                self.handleStreamState(state)
            }
        }
    }
    
    private func cancelStreamListeners() async {
        logger.info("🧹 Cancelling stream listeners...")
        await videoFrameListenerToken?.cancel()
        await photoListenerToken?.cancel()
        await errorListenerToken?.cancel()
        await stateListenerToken?.cancel()
        
        videoFrameListenerToken = nil
        photoListenerToken = nil
        errorListenerToken = nil
        stateListenerToken = nil
        logger.info("✅ Stream listeners cancelled")
    }
    
    private func handleStreamState(_ state: StreamSessionState) {
        logger.info("🎛️ Handling stream state: \(String(describing: state))")
        switch state {
        case .stopped:
            let hasDevice = deviceSelector?.activeDevice != nil
            logger.info("⏹️ Stream stopped, hasActiveDevice: \(hasDevice)")
            if hasDevice {
                connectionState = .connected
            } else {
                connectionState = .disconnected
            }
        case .waitingForDevice:
            logger.info("⏳ Waiting for device...")
            connectionState = .searching
        case .streaming:
            logger.info("🟢 Now streaming!")
            connectionState = .streaming
        case .starting:
            logger.info("🚀 Stream starting...")
            connectionState = .connecting
        case .stopping:
            logger.info("🛑 Stream stopping...")
            connectionState = .connecting
        case .paused:
            logger.info("⏸️ Stream paused")
            connectionState = .connected
        @unknown default:
            logger.warning("⚠️ Unknown stream state: \(String(describing: state))")
            break
        }
    }
}
