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
    @StateObject private var client = RealtimeAPIClient(apiKey: Config.openAIAPIKey)
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        // Connection status
                        ConnectionStatusCard(
                            connectionState: client.connectionState,
                            isSessionConfigured: client.isSessionConfigured,
                            voiceState: client.voiceState
                        )
                        
                        // Transcript area
                        if client.connectionState == .connected {
                            TranscriptCard(
                                userTranscript: client.userTranscript,
                                assistantTranscript: client.assistantTranscript,
                                voiceState: client.voiceState
                            )
                        }
                        
                        // Debug info
                        if !client.lastServerEvent.isEmpty {
                            DebugInfoCard(lastEvent: client.lastServerEvent)
                        }
                    }
                    .padding()
                }
                
                // Bottom controls
                ControlBar(
                    connectionState: client.connectionState,
                    voiceState: client.voiceState,
                    audioLevel: client.audioLevel,
                    onConnect: {
                        logger.info("🔌 Connect button tapped")
                        client.connect()
                    },
                    onDisconnect: {
                        logger.info("🔌 Disconnect button tapped")
                        client.disconnect()
                    },
                    onStartListening: {
                        logger.info("🎤 Start listening tapped")
                        client.startListening()
                    },
                    onStopListening: {
                        logger.info("🎤 Stop listening tapped")
                        client.stopListening()
                    }
                )
            }
            .navigationTitle("Voice Agent")
            .onAppear {
                logger.info("📱 Voice Agent tab appeared")
            }
            .onDisappear {
                logger.info("📱 Voice Agent tab disappeared")
            }
        }
    }
}

// MARK: - Connection Status Card

private struct ConnectionStatusCard: View {
    let connectionState: RealtimeConnectionState
    let isSessionConfigured: Bool
    let voiceState: VoiceState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Connection status row
            HStack(spacing: 12) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                
                Text(connectionState.displayText)
                    .font(.headline)
                
                Spacer()
                
                if connectionState == .connected {
                    Text(voiceStateText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(8)
                }
            }
            
            // Session status
            if connectionState == .connected {
                HStack(spacing: 16) {
                    Label(
                        isSessionConfigured ? "Session Ready" : "Configuring...",
                        systemImage: isSessionConfigured ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .font(.caption)
                    .foregroundColor(isSessionConfigured ? .green : .orange)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private var statusColor: Color {
        switch connectionState {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .connected: return .green
        case .error: return .red
        }
    }
    
    private var voiceStateText: String {
        switch voiceState {
        case .idle: return "Ready"
        case .listening: return "Listening..."
        case .processing: return "Processing..."
        case .speaking: return "Speaking..."
        }
    }
}

// MARK: - Transcript Card

private struct TranscriptCard: View {
    let userTranscript: String
    let assistantTranscript: String
    let voiceState: VoiceState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation")
                .font(.headline)
            
            if userTranscript.isEmpty && assistantTranscript.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Tap the microphone to start talking")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 32)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // User message
                    if !userTranscript.isEmpty {
                        MessageBubble(
                            text: userTranscript,
                            isUser: true,
                            isComplete: voiceState != .listening
                        )
                    }
                    
                    // Assistant message
                    if !assistantTranscript.isEmpty {
                        MessageBubble(
                            text: assistantTranscript,
                            isUser: false,
                            isComplete: voiceState == .idle
                        )
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

// MARK: - Control Bar

private struct ControlBar: View {
    let connectionState: RealtimeConnectionState
    let voiceState: VoiceState
    let audioLevel: Float
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onStartListening: () -> Void
    let onStopListening: () -> Void
    
    var body: some View {
        VStack(spacing: 12) {
            Divider()
            
            if connectionState != .connected {
                // Connect/Disconnect button
                if connectionState == .connecting {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Connecting...")
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if case .error(let message) = connectionState {
                    VStack(spacing: 8) {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                        
                        Button(action: onConnect) {
                            Label("Retry Connection", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else {
                    Button(action: onConnect) {
                        Label("Connect to OpenAI", systemImage: "waveform.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding()
                }
            } else {
                // Voice controls
                HStack(spacing: 20) {
                    // Disconnect button
                    Button(action: onDisconnect) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                    }
                    
                    Spacer()
                    
                    // Microphone button
                    MicrophoneButton(
                        voiceState: voiceState,
                        audioLevel: audioLevel,
                        onStartListening: onStartListening,
                        onStopListening: onStopListening
                    )
                    
                    Spacer()
                    
                    // Placeholder for symmetry
                    Color.clear
                        .frame(width: 44, height: 44)
                }
                .padding()
            }
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Microphone Button

private struct MicrophoneButton: View {
    let voiceState: VoiceState
    let audioLevel: Float
    let onStartListening: () -> Void
    let onStopListening: () -> Void
    
    @State private var isPulsing = false
    
    var body: some View {
        Button(action: {
            if voiceState == .idle {
                onStartListening()
            } else if voiceState == .listening {
                onStopListening()
            }
        }) {
            ZStack {
                // Pulsing background when listening
                if voiceState == .listening {
                    Circle()
                        .fill(Color.red.opacity(0.3))
                        .frame(width: 80 + CGFloat(audioLevel * 30), height: 80 + CGFloat(audioLevel * 30))
                        .animation(.easeInOut(duration: 0.1), value: audioLevel)
                }
                
                // Main button circle
                Circle()
                    .fill(buttonColor)
                    .frame(width: 72, height: 72)
                    .shadow(color: buttonColor.opacity(0.4), radius: 8, x: 0, y: 4)
                
                // Icon
                Image(systemName: buttonIcon)
                    .font(.title)
                    .foregroundColor(.white)
            }
        }
        .disabled(voiceState == .processing || voiceState == .speaking)
        .opacity(voiceState == .processing || voiceState == .speaking ? 0.6 : 1.0)
    }
    
    private var buttonColor: Color {
        switch voiceState {
        case .idle: return .blue
        case .listening: return .red
        case .processing: return .orange
        case .speaking: return .purple
        }
    }
    
    private var buttonIcon: String {
        switch voiceState {
        case .idle: return "mic.fill"
        case .listening: return "stop.fill"
        case .processing: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        }
    }
}

// MARK: - Debug Info Card

private struct DebugInfoCard: View {
    let lastEvent: String
    
    var body: some View {
        HStack {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.blue)
            Text("Last event:")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(lastEvent)
                .font(.caption.monospaced())
                .foregroundColor(.primary)
            Spacer()
        }
        .padding()
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
    }
}

#Preview {
    VoiceAgentView()
}
