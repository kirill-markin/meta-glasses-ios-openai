//
//  VoiceAgentView.swift
//  ai-glasses
//
//  Voice Agent tab with OpenAI Realtime API integration
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "VoiceAgentView")

struct VoiceAgentView: View {
    @ObservedObject var glassesManager: GlassesManager
    @StateObject private var client: RealtimeAPIClient
    @ObservedObject private var threadsManager = ThreadsManager.shared
    @ObservedObject private var permissionsManager = PermissionsManager.shared
    
    init(glassesManager: GlassesManager) {
        self.glassesManager = glassesManager
        self._client = StateObject(wrappedValue: RealtimeAPIClient(
            apiKey: Config.openAIAPIKey,
            glassesManager: glassesManager
        ))
    }
    
    var body: some View {
        NavigationStack {
            Group {
                // Check Bluetooth permission first (required for glasses connection)
                switch permissionsManager.bluetoothStatus {
                case .notDetermined:
                    BluetoothPermissionView(
                        state: .priming,
                        onRequestPermission: {
                            logger.info("📶 Requesting Bluetooth permission")
                            permissionsManager.requestBluetooth()
                        },
                        onOpenSettings: {
                            permissionsManager.openAppSettings()
                        }
                    )
                    
                case .denied, .restricted:
                    BluetoothPermissionView(
                        state: .denied,
                        onRequestPermission: {
                            permissionsManager.requestBluetooth()
                        },
                        onOpenSettings: {
                            logger.info("⚙️ Opening app settings for Bluetooth")
                            permissionsManager.openAppSettings()
                        }
                    )
                    
                case .authorized, .limited:
                    // Bluetooth OK - now check microphone permission
                    switch permissionsManager.microphoneStatus {
                    case .notDetermined:
                        // Pre-permission priming screen
                        MicrophonePermissionView(
                            state: .priming,
                            onRequestPermission: {
                                logger.info("🎤 Requesting microphone permission")
                                permissionsManager.requestMicrophone()
                            },
                            onOpenSettings: {
                                permissionsManager.openAppSettings()
                            }
                        )
                        
                    case .denied, .restricted:
                        // Permission denied screen
                        MicrophonePermissionView(
                            state: .denied,
                            onRequestPermission: {
                                permissionsManager.requestMicrophone()
                            },
                            onOpenSettings: {
                                logger.info("⚙️ Opening app settings for microphone")
                                permissionsManager.openAppSettings()
                            }
                        )
                        
                    case .authorized, .limited:
                        // Normal flow - both Bluetooth and microphone available
                        if client.connectionState == .connected {
                            // Connected state: show conversation UI
                            ConnectedView(
                                client: client,
                                onDisconnect: {
                                    logger.info("🔌 Disconnect button tapped")
                                    client.disconnect()
                                },
                                onToggleMute: {
                                    logger.info("🎤 Toggle mute tapped")
                                    client.toggleMute()
                                },
                                onForceResponse: {
                                    logger.info("🔘 Force response tapped")
                                    client.forceResponse()
                                }
                            )
                        } else {
                            // Disconnected/connecting/error state: show welcome screen
                            WelcomeView(
                                connectionState: client.connectionState,
                                onConnect: {
                                    logger.info("🔌 Connect button tapped")
                                    client.connect()
                                }
                            )
                        }
                    }
                }
            }
            .navigationTitle("Voice Agent")
            .onAppear {
                logger.info("📱 Voice Agent tab appeared")
                // Refresh permission status (user may have changed it in Settings)
                permissionsManager.refreshAll()
                checkPendingContinuation()
            }
            .onDisappear {
                logger.info("📱 Voice Agent tab disappeared")
            }
            .onChange(of: permissionsManager.bluetoothStatus) { oldValue, newValue in
                // When Bluetooth permission changes to authorized, check for pending continuation
                if newValue == .authorized && oldValue != .authorized {
                    logger.info("📶 Bluetooth permission granted")
                    checkPendingContinuation()
                }
            }
            .onChange(of: permissionsManager.microphoneStatus) { oldValue, newValue in
                // When permission changes to authorized, check for pending thread continuation
                if newValue == .authorized && oldValue != .authorized {
                    logger.info("🎤 Microphone permission granted")
                    checkPendingContinuation()
                }
            }
        }
    }
    
    /// Check if there's a pending thread continuation and auto-connect
    private func checkPendingContinuation() {
        guard let threadId = threadsManager.pendingContinuationThreadId else { return }
        
        // Don't auto-connect if Bluetooth not authorized - let user see permission screen first
        guard permissionsManager.bluetoothStatus == .authorized else {
            logger.info("⏸️ Pending thread continuation waiting for Bluetooth permission")
            return
        }
        
        // Don't auto-connect if microphone not authorized - let user see permission screen first
        guard permissionsManager.microphoneStatus == .authorized else {
            logger.info("⏸️ Pending thread continuation waiting for microphone permission")
            // Keep the pending thread ID so it will auto-connect after permission granted
            return
        }
        
        // Clear the pending continuation
        threadsManager.pendingContinuationThreadId = nil
        
        // Only auto-connect if not already connected
        guard client.connectionState == .disconnected else {
            logger.warning("⚠️ Cannot continue thread: already connected")
            return
        }
        
        logger.info("▶️ Auto-connecting to continue thread: \(threadId)")
        client.connect(threadId: threadId)
    }
}

// MARK: - Welcome View (Disconnected State)

private struct WelcomeView: View {
    let connectionState: RealtimeConnectionState
    let onConnect: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.2), Color.purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                
                // Text
                VStack(spacing: 12) {
                    Text("Voice Assistant")
                        .font(.title.bold())
                    
                    Text("Have a natural conversation with AI.\nAsk questions, get help, or just chat.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                
                // Action button or status
                VStack(spacing: 16) {
                    if connectionState == .connecting {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Connecting...")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 16)
                    } else if case .error(let message) = connectionState {
                        VStack(spacing: 12) {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            
                            Button(action: onConnect) {
                                Label("Try Again", systemImage: "arrow.clockwise")
                                    .font(.headline)
                                    .frame(maxWidth: 240)
                                    .padding(.vertical, 16)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                    } else {
                        Button(action: onConnect) {
                            HStack(spacing: 10) {
                                Image(systemName: "play.fill")
                                Text("Start Discussion")
                            }
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                }
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Connected View

private struct ConnectedView: View {
    @ObservedObject var client: RealtimeAPIClient
    let onDisconnect: () -> Void
    let onToggleMute: () -> Void
    let onForceResponse: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Session status (compact)
                    SessionStatusBar(
                        isSessionConfigured: client.isSessionConfigured,
                        voiceState: client.voiceState,
                        isMuted: client.isMuted
                    )
                    
                    // Transcript area
                    TranscriptCard(
                        messages: client.messages,
                        currentUserTranscript: client.userTranscript,
                        currentAssistantTranscript: client.assistantTranscript,
                        voiceState: client.voiceState
                    )
                }
                .padding()
            }
            
            // Bottom controls
            ControlBar(
                voiceState: client.voiceState,
                audioLevel: client.audioLevel,
                isMuted: client.isMuted,
                onDisconnect: onDisconnect,
                onToggleMute: onToggleMute,
                onForceResponse: onForceResponse
            )
        }
    }
}

// MARK: - Session Status Bar

private struct SessionStatusBar: View {
    let isSessionConfigured: Bool
    let voiceState: VoiceState
    let isMuted: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // Session status
            HStack(spacing: 6) {
                Circle()
                    .fill(isSessionConfigured ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                
                Text(isSessionConfigured ? "Connected" : "Configuring...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Muted indicator
            if isMuted {
                HStack(spacing: 4) {
                    Image(systemName: "mic.slash.fill")
                        .font(.caption)
                    Text("Muted")
                        .font(.caption.bold())
                }
                .foregroundColor(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.15))
                .cornerRadius(8)
            }
            
            // Voice state badge
            Text(voiceStateText)
                .font(.caption.bold())
                .foregroundColor(voiceStateColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(voiceStateColor.opacity(0.15))
                .cornerRadius(8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
    
    private var voiceStateText: String {
        switch voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .processing: return "Thinking..."
        case .speaking: return "Speaking..."
        }
    }
    
    private var voiceStateColor: Color {
        switch voiceState {
        case .idle: return .secondary
        case .listening: return .red
        case .processing: return .orange
        case .speaking: return .purple
        }
    }
}

// MARK: - Transcript Card

private struct TranscriptCard: View {
    let messages: [ChatMessage]
    let currentUserTranscript: String
    let currentAssistantTranscript: String
    let voiceState: VoiceState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation")
                .font(.headline)
            
            if messages.isEmpty && currentUserTranscript.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Start speaking, I'm listening...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 32)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // All previous messages
                    ForEach(messages) { message in
                        MessageBubble(
                            text: message.text,
                            isUser: message.isUser,
                            isComplete: true
                        )
                    }
                    
                    // Current streaming assistant transcript (before it's finalized)
                    if voiceState == .speaking && !currentAssistantTranscript.isEmpty {
                        if messages.last?.text != currentAssistantTranscript {
                            MessageBubble(
                                text: currentAssistantTranscript,
                                isUser: false,
                                isComplete: false
                            )
                        }
                    }
                    
                    // Processing indicator
                    if voiceState == .processing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Thinking...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

private struct MessageBubble: View {
    let text: String
    let isUser: Bool
    let isComplete: Bool
    
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: isUser ? "person.fill" : "sparkles")
                        .font(.caption)
                        .foregroundColor(isUser ? .blue : .purple)
                    Text(isUser ? "You" : "Assistant")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                }
                
                Text(text)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                    .cornerRadius(12)
            }
            
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Control Bar (Connected State Only)

private struct ControlBar: View {
    let voiceState: VoiceState
    let audioLevel: Float
    let isMuted: Bool
    let onDisconnect: () -> Void
    let onToggleMute: () -> Void
    let onForceResponse: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Divider()
            
            // Smart detection hint
            if !isMuted && (voiceState == .idle || voiceState == .listening) {
                Text("AI will detect when you're ready for a response")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if isMuted {
                Text("Microphone is muted")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            
            // Voice controls
            HStack(spacing: 20) {
                // Disconnect button
                Button(action: onDisconnect) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                
                Spacer()
                
                // Mute/Unmute button
                MuteButton(
                    isMuted: isMuted,
                    voiceState: voiceState,
                    audioLevel: audioLevel,
                    onToggleMute: onToggleMute
                )
                
                Spacer()
                
                // Force response button (fallback if user forgot trigger phrase)
                Button(action: onForceResponse) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                }
                .disabled(voiceState == .speaking || voiceState == .processing)
                .opacity(voiceState == .speaking || voiceState == .processing ? 0.4 : 1.0)
            }
            .padding()
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Mute Button

private struct MuteButton: View {
    let isMuted: Bool
    let voiceState: VoiceState
    let audioLevel: Float
    let onToggleMute: () -> Void
    
    var body: some View {
        Button(action: onToggleMute) {
            ZStack {
                // Main button circle
                Circle()
                    .fill(buttonColor)
                    .frame(width: 72, height: 72)
                    .shadow(color: buttonColor.opacity(0.4), radius: 8, x: 0, y: 4)
                
                // Icon
                Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.title)
                    .foregroundColor(.white)
            }
            // Fixed frame prevents layout jumping when glow animates
            .frame(width: 110, height: 110)
            // Pulsing background when listening and not muted (as background to not affect layout)
            .background {
                if voiceState == .listening && !isMuted {
                    Circle()
                        .fill(Color.blue.opacity(0.3))
                        .frame(width: 80 + CGFloat(audioLevel * 30), height: 80 + CGFloat(audioLevel * 30))
                        .animation(.easeInOut(duration: 0.1), value: audioLevel)
                }
            }
        }
    }
    
    private var buttonColor: Color {
        if isMuted {
            return .gray
        }
        switch voiceState {
        case .idle: return .blue
        case .listening: return .blue
        case .processing: return .orange
        case .speaking: return .purple
        }
    }
}

// MARK: - Permission State

enum PermissionPrimingState {
    case priming      // Before first system request
    case denied       // User denied permission
}

// MARK: - Bluetooth Permission View

private struct BluetoothPermissionView: View {
    let state: PermissionPrimingState
    let onRequestPermission: () -> Void
    let onOpenSettings: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: state == .priming
                                    ? [Color.blue.opacity(0.2), Color.cyan.opacity(0.2)]
                                    : [Color.orange.opacity(0.2), Color.red.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: state == .priming ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: state == .priming ? [.blue, .cyan] : [.orange, .red],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                
                // Text
                VStack(spacing: 12) {
                    Text(state == .priming ? "Bluetooth Access Required" : "Bluetooth Access Denied")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    
                    Text(state == .priming
                         ? "Bluetooth is required to connect to your Meta Glasses.\nWithout Bluetooth, this app cannot function."
                         : "You've previously denied Bluetooth access.\nBluetooth is required to connect to glasses — without it, the app cannot function.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                
                // Action button
                VStack(spacing: 16) {
                    if state == .priming {
                        Button(action: onRequestPermission) {
                            HStack(spacing: 10) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                Text("Allow Bluetooth")
                            }
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button(action: onOpenSettings) {
                            HStack(spacing: 10) {
                                Image(systemName: "gear")
                                Text("Open Settings")
                            }
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        
                        Text("After enabling, return to the app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - Microphone Permission View

private struct MicrophonePermissionView: View {
    let state: PermissionPrimingState
    let onRequestPermission: () -> Void
    let onOpenSettings: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(spacing: 32) {
                // Icon
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: state == .priming
                                    ? [Color.blue.opacity(0.2), Color.purple.opacity(0.2)]
                                    : [Color.orange.opacity(0.2), Color.red.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: state == .priming ? "mic.fill" : "mic.slash.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: state == .priming ? [.blue, .purple] : [.orange, .red],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                
                // Text
                VStack(spacing: 12) {
                    Text(state == .priming ? "Microphone Access Required" : "Microphone Access Denied")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    
                    Text(state == .priming
                         ? "Microphone is required to talk to AI through this app.\nWithout microphone access, this app cannot function."
                         : "You've previously denied microphone access.\nMicrophone is required for voice conversations — without it, the app cannot function.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                
                // Action button
                VStack(spacing: 16) {
                    if state == .priming {
                        Button(action: onRequestPermission) {
                            HStack(spacing: 10) {
                                Image(systemName: "mic.fill")
                                Text("Allow Microphone")
                            }
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    } else {
                        Button(action: onOpenSettings) {
                            HStack(spacing: 10) {
                                Image(systemName: "gear")
                                Text("Open Settings")
                            }
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        
                        Text("After enabling, return to the app")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    VoiceAgentView(glassesManager: GlassesManager())
}
