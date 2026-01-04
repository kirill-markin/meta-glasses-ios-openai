//
//  ContentView.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import SwiftUI
import UIKit
import MWDATCamera
import AVFoundation
import AVKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "ContentView")

enum AppTab: Int {
    case voiceAgent = 0
    case threads = 1
    case settings = 2
    
    var name: String {
        switch self {
        case .voiceAgent: return "Voice Agent"
        case .threads: return "Threads"
        case .settings: return "Settings"
        }
    }
}

// MARK: - Lazy View

/// Wrapper that delays View creation until it's actually displayed.
/// Use this in NavigationLink destinations to prevent blocking the UI during navigation.
struct LazyView<Content: View>: View {
    let build: () -> Content
    
    init(_ build: @autoclosure @escaping () -> Content) {
        self.build = build
    }
    
    var body: Content {
        build()
    }
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .voiceAgent
    @StateObject private var glassesManager = GlassesManager()
    @ObservedObject private var permissionsManager = PermissionsManager.shared
    
    var body: some View {
        Group {
            if glassesManager.isInitialized {
                TabView(selection: $selectedTab) {
                    LazyView(VoiceAgentView(glassesManager: glassesManager))
                        .tabItem {
                            Label("Voice Agent", systemImage: "waveform.circle")
                        }
                        .tag(AppTab.voiceAgent)
                    
                    ThreadsView(onContinueThread: {
                            selectedTab = .voiceAgent
                        })
                        .tabItem {
                            Label("Threads", systemImage: "bubble.left.and.bubble.right")
                        }
                        .tag(AppTab.threads)
                    
                    SettingsView(glassesManager: glassesManager)
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tag(AppTab.settings)
                        .badge(permissionsManager.missingRequiredPermissionsCount > 0
                               ? permissionsManager.missingRequiredPermissionsCount
                               : 0)
                }
                .onChange(of: selectedTab) { oldValue, newValue in
                    logger.info("📑 Tab changed: \(oldValue.name) → \(newValue.name)")
                }
            } else {
                LoadingView()
            }
        }
    }
}

// MARK: - Loading View

private struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "eyeglasses")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Initializing...")
                .font(.headline)
                .foregroundColor(.secondary)
            
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .background(SystemPreloader())
    }
}

// MARK: - System Preloader

/// Preloads various systems during loading screen to avoid delays on first use
private struct SystemPreloader: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.isHidden = true
        
        // Create hidden text field to trigger keyboard preload
        let textField = UITextField(frame: .zero)
        textField.isHidden = true
        container.addSubview(textField)
        
        // Preload systems in background
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // 1. Preload keyboard
            textField.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                textField.resignFirstResponder()
            }
            
            // 2. Preload SettingsManager (triggers file load)
            Task { @MainActor in
                _ = SettingsManager.shared.memories
            }
            
            // 3. Preload ThreadsManager (triggers file load)
            Task { @MainActor in
                _ = ThreadsManager.shared.threads
            }
            
            // 4. Preload SoundManager (warm up audio engine with silent tone)
            Task { @MainActor in
                _ = SoundManager.shared
            }
        }
        
        return container
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Glasses Tab

struct GlassesTab: View {
    @ObservedObject var glassesManager: GlassesManager
    @State private var selectedMediaItem: MediaItem?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Registration section (if not registered)
                    if !glassesManager.isRegistered {
                        RegistrationSection(onRegister: { glassesManager.register() })
                    }
                    
                    // Show main UI only after registration
                    if glassesManager.isRegistered {
                        // Status section
                        StatusSection(
                            state: glassesManager.connectionState,
                            isRegistered: glassesManager.isRegistered,
                            deviceCount: glassesManager.availableDevices.count
                        )
                        
                        // Video preview (only when streaming)
                        if glassesManager.connectionState == .streaming {
                            VideoPreviewSection(
                                frame: glassesManager.currentFrame,
                                isRecording: glassesManager.recordingState == .recording
                            )
                        }
                        
                        // Controls
                        ControlsSection(
                            state: glassesManager.connectionState,
                            isRegistered: glassesManager.isRegistered,
                            recordingState: glassesManager.recordingState,
                            isAudioConfigured: glassesManager.isAudioConfigured,
                            onConnect: { glassesManager.startSearching() },
                            onDisconnect: { glassesManager.disconnect() },
                            onStartStream: { glassesManager.startStreaming() },
                            onStopStream: { glassesManager.stopStreaming() },
                            onCapturePhoto: { glassesManager.capturePhoto() },
                            onStartQuickVideo: { glassesManager.startQuickVideoRecording() },
                            onStopQuickVideo: { glassesManager.stopQuickVideoRecording() },
                            onStartRecording: { glassesManager.startRecording() },
                            onStopRecording: { glassesManager.stopRecording() }
                        )
                        
                        // Audio Recording (Bluetooth only, no DAT required)
                        AudioRecordingSection(
                            audioRecordingState: glassesManager.audioRecordingState,
                            currentInput: glassesManager.currentAudioInput,
                            isBluetoothAvailable: glassesManager.checkBluetoothAudioAvailable(),
                            onStartRecording: { glassesManager.startAudioRecording() },
                            onStopRecording: { glassesManager.stopAudioRecording() },
                            onRefreshInput: { glassesManager.refreshAudioInputInfo() }
                        )
                        
                        // Media grid
                        if !glassesManager.capturedMedia.isEmpty {
                            MediaGridView(
                                media: glassesManager.capturedMedia,
                                selectedItem: $selectedMediaItem
                            )
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Glasses")
            .fullScreenCover(item: $selectedMediaItem) { item in
                MediaDetailView(item: item)
            }
        }
    }
}

// MARK: - Status Section

private struct StatusSection: View {
    let state: GlassesConnectionState
    let isRegistered: Bool
    let deviceCount: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                
                Text(state.displayText)
                    .font(.headline)
                
                Spacer()
            }
            
            HStack(spacing: 16) {
                Label(isRegistered ? "Registered" : "Not Registered", 
                      systemImage: isRegistered ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.caption)
                    .foregroundColor(isRegistered ? .green : .orange)
                
                Label("\(deviceCount) device(s)", systemImage: "eyeglasses")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var statusColor: Color {
        switch state {
        case .disconnected:
            return .gray
        case .searching, .connecting:
            return .orange
        case .connected:
            return .blue
        case .streaming:
            return .green
        case .error:
            return .red
        }
    }
}

// MARK: - Registration Section

private struct RegistrationSection: View {
    let onRegister: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Register with Meta AI app to access glasses")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: onRegister) {
                Label("Register App", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Video Preview Section

private struct VideoPreviewSection: View {
    let frame: VideoFrame?
    let isRecording: Bool
    
    var body: some View {
        ZStack {
            // Fixed 16:9 horizontal container
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black)
            
            if let frame = frame {
                VideoFrameView(frame: frame)
            } else {
                ProgressView()
                    .tint(.white)
            }
            
            // Recording indicator
            if isRecording {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("REC")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                        .padding(12)
                    }
                    Spacer()
                }
            }
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Video Frame View

private struct VideoFrameView: View {
    let frame: VideoFrame
    
    var body: some View {
        // Convert VideoFrame to displayable image
        if let uiImage = frame.makeUIImage() {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.black
        }
    }
}

// MARK: - Controls Section

private struct ControlsSection: View {
    let state: GlassesConnectionState
    let isRegistered: Bool
    let recordingState: RecordingState
    let isAudioConfigured: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onStartStream: () -> Void
    let onStopStream: () -> Void
    let onCapturePhoto: () -> Void
    let onStartQuickVideo: () -> Void
    let onStopQuickVideo: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            // Audio status indicator when streaming
            if state == .streaming {
                HStack(spacing: 8) {
                    Image(systemName: isAudioConfigured ? "mic.fill" : "mic.slash")
                        .foregroundColor(isAudioConfigured ? .green : .orange)
                    Text(isAudioConfigured ? "Audio ready" : "Audio not available")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            // Connection button
            if state.isConnected {
                Button(action: onDisconnect) {
                    Label("Disconnect", systemImage: "wifi.slash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(recordingState == .recording)
            } else {
                Button(action: onConnect) {
                    Label("Connect to Glasses", systemImage: "wifi")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state == .searching || state == .connecting || !isRegistered)
            }
            
            // Streaming controls
            if state.isConnected {
                VStack(spacing: 12) {
                    if state == .streaming {
                        Button(action: onStopStream) {
                            Label("Stop Stream", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(recordingState == .recording)
                    } else {
                        Button(action: onStartStream) {
                            Label("Start Stream", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recordingState == .recording)
                    }
                    
                    Button(action: onCapturePhoto) {
                        Label("Capture Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(recordingState == .recording)
                    
                    // Quick Video button (works like Photo - starts stream if needed)
                    if recordingState == .recording {
                        Button(action: onStopQuickVideo) {
                            Label("Stop Recording", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(action: onStartQuickVideo) {
                            Label("Record Video", systemImage: "video.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(recordingState == .finishing)
                    }
                }
                
                // Finishing indicator
                if recordingState == .finishing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Saving video...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if case .error(let message) = recordingState {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }
}

// MARK: - Audio Recording Section

private struct AudioRecordingSection: View {
    let audioRecordingState: AudioRecordingState
    let currentInput: String
    let isBluetoothAvailable: Bool
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onRefreshInput: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.purple)
                Text("Audio Recording")
                    .font(.headline)
                Spacer()
                
                // Refresh button
                Button(action: onRefreshInput) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            
            // Audio input status
            HStack(spacing: 8) {
                Image(systemName: isBluetoothAvailable ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundColor(isBluetoothAvailable ? .green : .orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(isBluetoothAvailable ? "Bluetooth Available" : "No Bluetooth Audio")
                        .font(.caption)
                        .foregroundColor(isBluetoothAvailable ? .green : .orange)
                    Text(currentInput)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
            
            // Recording indicator
            if audioRecordingState == .recording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                    Text("Recording audio...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            
            // Record button
            if audioRecordingState == .recording {
                Button(action: onStopRecording) {
                    Label("Stop Audio Recording", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button(action: onStartRecording) {
                    Label("Record Audio", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(audioRecordingState == .finishing)
            }
            
            // Finishing indicator
            if audioRecordingState == .finishing {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Saving audio...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Error message
            if case .error(let message) = audioRecordingState {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            // Info text
            Text("Records from Bluetooth microphone (glasses). No DAT stream required.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

// MARK: - Media Grid View

private struct MediaGridView: View {
    let media: [MediaItem]
    @Binding var selectedItem: MediaItem?
    
    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Captured Media")
                .font(.caption)
                .foregroundColor(.secondary)
            
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(media) { item in
                    MediaThumbnailView(item: item)
                        .onTapGesture {
                            selectedItem = item
                        }
                }
            }
        }
    }
}

// MARK: - Media Thumbnail View

private struct MediaThumbnailView: View {
    let item: MediaItem
    
    var body: some View {
        ZStack {
            switch item {
            case .photo(_, let data, _):
                if let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                        .cornerRadius(8)
                }
                
            case .video(_, let url, _):
                VideoThumbnailView(url: url)
                    .aspectRatio(1, contentMode: .fit)
                    .clipped()
                    .cornerRadius(8)
                    .overlay(
                        Image(systemName: "play.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    )
                
            case .audio(_, _, _):
                Rectangle()
                    .fill(Color.purple.opacity(0.3))
                    .aspectRatio(1, contentMode: .fit)
                    .cornerRadius(8)
                    .overlay(
                        VStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .font(.title)
                                .foregroundColor(.purple)
                            Image(systemName: "play.circle.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                    )
            }
        }
    }
}

// MARK: - Video Thumbnail View

private struct VideoThumbnailView: View {
    let url: URL
    @State private var thumbnail: UIImage?
    
    var body: some View {
        Group {
            if let thumbnail = thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(.tertiarySystemBackground))
                    .overlay(
                        Image(systemName: "film")
                            .foregroundColor(.secondary)
                    )
            }
        }
        .onAppear {
            generateThumbnail()
        }
    }
    
    private func generateThumbnail() {
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let imageGenerator = AVAssetImageGenerator(asset: asset)
            imageGenerator.appliesPreferredTrackTransform = true
            imageGenerator.maximumSize = CGSize(width: 200, height: 200)
            
            do {
                let (cgImage, _) = try await imageGenerator.image(at: .zero)
                let uiImage = UIImage(cgImage: cgImage)
                await MainActor.run {
                    self.thumbnail = uiImage
                }
            } catch {
                // Thumbnail generation failed, keep placeholder
            }
        }
    }
}

// MARK: - Media Detail View

private struct MediaDetailView: View {
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                switch item {
                case .photo(_, let data, _):
                    PhotoDetailContent(data: data)
                    
                case .video(_, let url, _):
                    VideoDetailContent(url: url)
                    
                case .audio(_, let url, _):
                    AudioDetailContent(url: url)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showShareSheet = true }) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [shareItem])
            }
        }
    }
    
    private var shareItem: Any {
        switch item {
        case .photo(_, let data, _):
            return data
        case .video(_, let url, _):
            return url
        case .audio(_, let url, _):
            return url
        }
    }
}

// MARK: - Photo Detail Content

private struct PhotoDetailContent: View {
    let data: Data
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    
    var body: some View {
        if let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = lastScale * value
                        }
                        .onEnded { _ in
                            lastScale = scale
                            // Limit zoom range
                            if scale < 1.0 {
                                withAnimation {
                                    scale = 1.0
                                    lastScale = 1.0
                                }
                            } else if scale > 4.0 {
                                withAnimation {
                                    scale = 4.0
                                    lastScale = 4.0
                                }
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1.0 {
                            scale = 1.0
                            lastScale = 1.0
                        } else {
                            scale = 2.0
                            lastScale = 2.0
                        }
                    }
                }
        }
    }
}

// MARK: - Video Detail Content

private struct VideoDetailContent: View {
    let url: URL
    @State private var player: AVPlayer?
    
    var body: some View {
        Group {
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .onAppear {
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Audio Detail Content

private struct AudioDetailContent: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying: Bool = false
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var timeObserver: Any?
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Waveform icon
            Image(systemName: "waveform")
                .font(.system(size: 80))
                .foregroundColor(.purple)
            
            // File name
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Progress bar
            VStack(spacing: 8) {
                ProgressView(value: duration > 0 ? currentTime / duration : 0)
                    .progressViewStyle(.linear)
                    .tint(.purple)
                
                HStack {
                    Text(formatTime(currentTime))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 40)
            
            // Playback controls
            HStack(spacing: 40) {
                // Rewind 15s
                Button(action: { seek(by: -15) }) {
                    Image(systemName: "gobackward.15")
                        .font(.title)
                        .foregroundColor(.white)
                }
                
                // Play/Pause
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundColor(.purple)
                }
                
                // Forward 15s
                Button(action: { seek(by: 15) }) {
                    Image(systemName: "goforward.15")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
            
            Spacer()
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanupPlayer()
        }
    }
    
    private func setupPlayer() {
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // Get duration
        Task {
            if let duration = try? await playerItem.asset.load(.duration) {
                await MainActor.run {
                    self.duration = CMTimeGetSeconds(duration)
                }
            }
        }
        
        // Add time observer
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            currentTime = CMTimeGetSeconds(time)
        }
        
        // Observe playback end
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            isPlaying = false
            player?.seek(to: .zero)
        }
    }
    
    private func cleanupPlayer() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        player = nil
    }
    
    private func togglePlayback() {
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
        isPlaying.toggle()
    }
    
    private func seek(by seconds: Double) {
        guard let player = player else { return }
        let current = CMTimeGetSeconds(player.currentTime())
        let newTime = max(0, min(duration, current + seconds))
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: CMTimeScale(NSEC_PER_SEC)))
    }
    
    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Share Sheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
}
