//
//  ContentView.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import SwiftUI
import MWDATCamera
import AVFoundation
import AVKit

struct ContentView: View {
    @StateObject private var glassesManager = GlassesManager()
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
                        
                        // Video preview
                        VideoPreviewSection(
                            frame: glassesManager.currentFrame,
                            isStreaming: glassesManager.connectionState == .streaming,
                            isRecording: glassesManager.recordingState == .recording
                        )
                        
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
            .navigationTitle("AI Glasses")
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
    let isStreaming: Bool
    let isRecording: Bool
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black)
                .aspectRatio(16/9, contentMode: .fit)
            
            if isStreaming {
                if let frame = frame {
                    VideoFrameView(frame: frame)
                        .cornerRadius(16)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No video stream")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
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
