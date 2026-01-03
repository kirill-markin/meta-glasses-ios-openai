//
//  ContentView.swift
//  ai-glasses
//
//  Created by Kirill Markin on 03/01/2026.
//

import SwiftUI
import MWDATCamera

struct ContentView: View {
    @StateObject private var glassesManager = GlassesManager()
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Status section
                StatusSection(
                    state: glassesManager.connectionState,
                    isRegistered: glassesManager.isRegistered,
                    deviceCount: glassesManager.availableDevices.count
                )
                
                // Registration section (if not registered)
                if !glassesManager.isRegistered {
                    RegistrationSection(onRegister: { glassesManager.register() })
                }
                
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
                
                // Photo preview
                if let photoData = glassesManager.lastCapturedPhoto,
                   let uiImage = UIImage(data: photoData) {
                    PhotoPreviewSection(image: uiImage)
                }
                
                // Video preview
                if let videoURL = glassesManager.lastRecordedVideoURL {
                    VideoFileSection(videoURL: videoURL)
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("AI Glasses")
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
                HStack(spacing: 16) {
                    if state == .streaming {
                        Button(action: onStopStream) {
                            Label("Stop", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(recordingState == .recording)
                    } else {
                        Button(action: onStartStream) {
                            Label("Stream", systemImage: "video.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(recordingState == .recording)
                    }
                    
                    Button(action: onCapturePhoto) {
                        Label("Photo", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(recordingState == .recording)
                    
                    // Quick Video button (works like Photo - starts stream if needed)
                    if recordingState == .recording {
                        Button(action: onStopQuickVideo) {
                            Label("Stop", systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(action: onStartQuickVideo) {
                            Label("Video", systemImage: "video.circle.fill")
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

// MARK: - Photo Preview Section

private struct PhotoPreviewSection: View {
    let image: UIImage
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Captured Photo")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 120)
                .cornerRadius(8)
        }
    }
}

// MARK: - Video File Section

private struct VideoFileSection: View {
    let videoURL: URL
    @State private var showShareSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Recorded Video")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button(action: { showShareSheet = true }) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption)
                }
            }
            
            HStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(videoURL.lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                    
                    if let fileSize = getFileSize(url: videoURL) {
                        Text(fileSize)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding()
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(8)
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [videoURL])
        }
    }
    
    private func getFileSize(url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int64 else {
            return nil
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
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
