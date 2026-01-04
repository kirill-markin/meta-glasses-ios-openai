//
//  RealtimeAPIClient.swift
//  ai-glasses
//
//  WebSocket client for OpenAI Realtime API with audio capture and playback
//

import Foundation
import Combine
import AVFoundation
import os.log

// MARK: - Connection State

enum RealtimeConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
    
    var displayText: String {
        switch self {
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - Voice State

enum VoiceState: Equatable {
    case idle
    case listening
    case processing
    case speaking
}

// MARK: - Chat Message

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let isUser: Bool
    var text: String
    let timestamp: Date
    
    init(isUser: Bool, text: String) {
        self.id = UUID()
        self.isUser = isUser
        self.text = text
        self.timestamp = Date()
    }
}

// MARK: - Realtime API Client

@MainActor
final class RealtimeAPIClient: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var connectionState: RealtimeConnectionState = .disconnected
    @Published private(set) var voiceState: VoiceState = .idle
    @Published private(set) var lastServerEvent: String = ""
    @Published private(set) var isSessionConfigured: Bool = false
    @Published private(set) var userTranscript: String = ""
    @Published private(set) var assistantTranscript: String = ""
    @Published private(set) var audioLevel: Float = 0.0
    @Published private(set) var messages: [ChatMessage] = []
    
    // MARK: - Private Properties
    
    private var webSocket: URLSessionWebSocketTask?
    private let apiKey: String
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai-glasses", category: "RealtimeAPI")
    
    private let realtimeURL = "wss://api.openai.com/v1/realtime?model=gpt-realtime"
    
    // Audio Engine
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let audioSession = AVAudioSession.sharedInstance()
    
    // Audio format for OpenAI (24kHz, 16-bit, mono)
    private let openAISampleRate: Double = 24000
    private let openAIChannels: AVAudioChannelCount = 1
    
    // Audio buffer for playback
    private var pendingAudioData = Data()
    private var isPlaying = false
    
    // Saved playback format to ensure consistent buffer scheduling
    private var playbackFormat: AVAudioFormat?
    
    // Track pending user message to ensure correct ordering
    private var pendingUserMessageId: UUID?
    
    // Conversation history for intent detection context
    private var recentTranscripts: [String] = []
    private let maxRecentTranscripts = 5
    
    // Track if response is currently active (for barge-in)
    private var isResponseActive = false
    
    // Track if assistant message was already finalized (for barge-in deduplication)
    private var assistantMessageFinalized = false
    
    // Track pending audio buffers to know when playback is actually finished
    private var pendingAudioBufferCount = 0
    
    // Track if we received response.done (separate from actual playback completion)
    private var responseGenerationComplete = false
    
    // MARK: - Initialization
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    deinit {
        // Clean up audio engine synchronously
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
    }
    
    // MARK: - Public Methods
    
    func connect() {
        guard connectionState == .disconnected || connectionState != .connecting else {
            logger.warning("Already connecting or connected")
            return
        }
        
        connectionState = .connecting
        logger.info("Connecting to Realtime API...")
        
        guard let url = URL(string: realtimeURL) else {
            connectionState = .error("Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()
        
        // Start receiving messages
        receiveMessage()
        
        // Configure session after connection
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await configureSession()
        }
    }
    
    func disconnect() {
        logger.info("Disconnecting from Realtime API")
        stopListening()
        stopAudioEngine()
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        connectionState = .disconnected
        isSessionConfigured = false
        voiceState = .idle
        userTranscript = ""
        assistantTranscript = ""
        messages = []
        pendingUserMessageId = nil
        pendingAudioBufferCount = 0
        responseGenerationComplete = false
    }
    
    /// Start listening to microphone and streaming to OpenAI
    func startListening() {
        guard connectionState == .connected, isSessionConfigured else {
            logger.warning("Cannot start listening: not connected or not configured")
            return
        }
        
        guard voiceState == .idle else {
            logger.warning("Cannot start listening: already in voice state \(String(describing: self.voiceState))")
            return
        }
        
        logger.info("🎤 Starting to listen...")
        userTranscript = ""
        assistantTranscript = ""
        
        do {
            try setupAudioSession()
            try startAudioEngine()
            voiceState = .listening
        } catch {
            logger.error("❌ Failed to start listening: \(error.localizedDescription)")
            connectionState = .error("Audio setup failed: \(error.localizedDescription)")
        }
    }
    
    /// Stop listening (VAD handles response triggering via trigger phrases)
    func stopListening() {
        guard voiceState == .listening || voiceState == .processing else { return }
        
        logger.info("🎤 Stopping listening...")
        stopAudioCapture()
        
        // Commit any remaining audio
        commitAudioBuffer()
        
        voiceState = .idle
    }
    
    /// Force request a response (button fallback if user forgot trigger phrase)
    func forceResponse() {
        guard connectionState == .connected, isSessionConfigured else {
            logger.warning("Cannot force response: not connected or not configured")
            return
        }
        
        logger.info("🔘 Force response requested")
        
        // Note: With Server VAD, the buffer is automatically committed when speech stops,
        // so we just need to request a response - no need to commit again
        
        // Request response
        requestResponse()
        
        voiceState = .processing
    }
    
    // MARK: - Audio Session Setup
    
    private func setupAudioSession() throws {
        logger.info("🔊 Setting up audio session...")
        
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // Log current audio route
        let currentRoute = audioSession.currentRoute
        for input in currentRoute.inputs {
            logger.info("🎤 Audio input: \(input.portName) (\(input.portType.rawValue))")
        }
        for output in currentRoute.outputs {
            logger.info("🔊 Audio output: \(output.portName) (\(output.portType.rawValue))")
        }
    }
    
    // MARK: - Audio Engine
    
    private func startAudioEngine() throws {
        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        
        guard let audioEngine = audioEngine, let playerNode = playerNode else {
            throw NSError(domain: "RealtimeAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio engine"])
        }
        
        // Attach player node for playback
        audioEngine.attach(playerNode)
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        logger.info("📊 Input format: \(inputFormat.sampleRate) Hz, \(inputFormat.channelCount) ch")
        
        // Create format for OpenAI (24kHz, mono, PCM16)
        guard let openAIFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: openAISampleRate,
            channels: openAIChannels,
            interleaved: true
        ) else {
            throw NSError(domain: "RealtimeAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create OpenAI audio format"])
        }
        
        // Connect player to output for playback
        let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        playbackFormat = outputFormat
        logger.info("📊 Output format: \(outputFormat.sampleRate) Hz, \(outputFormat.channelCount) ch")
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: outputFormat)
        
        // Create converter for input resampling
        guard let converter = AVAudioConverter(from: inputFormat, to: openAIFormat) else {
            throw NSError(domain: "RealtimeAPI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
        }
        
        // Install tap on input for capturing audio
        let bufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer, converter: converter, outputFormat: openAIFormat)
        }
        
        try audioEngine.start()
        playerNode.play()
        
        logger.info("✅ Audio engine started")
    }
    
    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        playbackFormat = nil
        
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        
        logger.info("🔇 Audio engine stopped")
    }
    
    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        logger.info("🎤 Audio capture stopped")
    }
    
    private func processInputBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, outputFormat: AVAudioFormat) {
        // Calculate audio level for UI
        if let channelData = buffer.floatChannelData?[0] {
            let frameCount = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameCount {
                sum += abs(channelData[i])
            }
            let avgLevel = sum / Float(frameCount)
            
            Task { @MainActor in
                self.audioLevel = avgLevel * 10 // Scale for visibility
            }
        }
        
        // Convert to OpenAI format
        let outputFrameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate
        )
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCapacity) else {
            return
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            logger.error("❌ Conversion error: \(error.localizedDescription)")
            return
        }
        
        // Get PCM data and send to OpenAI
        guard let int16Data = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        let data = Data(bytes: int16Data[0], count: frameLength * 2) // 2 bytes per sample
        
        Task { @MainActor in
            self.sendAudio(pcmData: data)
        }
    }
    
    // MARK: - Audio Playback
    
    private func playAudioData(_ data: Data) {
        guard audioEngine != nil,
              let playerNode = playerNode,
              let outputFormat = playbackFormat else {
            logger.warning("⚠️ Cannot play audio: engine not running or no playback format")
            return
        }
        
        // Create buffer from PCM16 data in OpenAI format (24kHz, mono)
        let frameCount = data.count / 2 // 2 bytes per sample
        
        guard let openAIFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: openAISampleRate,
            channels: openAIChannels,
            interleaved: false
        ),
        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: openAIFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            logger.error("❌ Failed to create source buffer")
            return
        }
        
        sourceBuffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Convert Int16 to Float32
        data.withUnsafeBytes { rawBuffer in
            let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
            guard let floatData = sourceBuffer.floatChannelData?[0] else { return }
            
            for i in 0..<frameCount {
                floatData[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }
        
        // Always convert to output format (handles both sample rate and channel count differences)
        let needsConversion = openAIFormat.sampleRate != outputFormat.sampleRate ||
                              openAIFormat.channelCount != outputFormat.channelCount
        
        // Increment pending buffer count before scheduling
        pendingAudioBufferCount += 1
        
        // Completion handler for tracking actual playback completion
        // Uses @Sendable closure for thread safety
        let completionHandler: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioBufferPlaybackComplete()
            }
        }
        
        if needsConversion {
            guard let converter = AVAudioConverter(from: openAIFormat, to: outputFormat) else {
                logger.error("❌ Failed to create playback converter")
                pendingAudioBufferCount -= 1
                return
            }
            
            let outputFrameCount = AVAudioFrameCount(
                Double(frameCount) * outputFormat.sampleRate / openAIFormat.sampleRate
            )
            
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
                logger.error("❌ Failed to create output buffer")
                pendingAudioBufferCount -= 1
                return
            }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            
            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            
            if let error = error {
                logger.error("❌ Conversion error: \(error.localizedDescription)")
                pendingAudioBufferCount -= 1
                return
            }
            
            // Use .dataPlayedBack to get callback only after audio is actually played
            playerNode.scheduleBuffer(outputBuffer, completionCallbackType: .dataPlayedBack, completionHandler: completionHandler)
        } else {
            playerNode.scheduleBuffer(sourceBuffer, completionCallbackType: .dataPlayedBack, completionHandler: completionHandler)
        }
    }
    
    /// Called when an audio buffer finishes playing (via .dataPlayedBack callback)
    private func handleAudioBufferPlaybackComplete() {
        pendingAudioBufferCount -= 1
        
        // Only transition to idle when ALL buffers are done AND response generation is complete
        if pendingAudioBufferCount <= 0 && responseGenerationComplete {
            pendingAudioBufferCount = 0
            if voiceState == .speaking {
                voiceState = .idle
                logger.info("🔇 All audio buffers finished playing")
            }
        }
    }
    
    // MARK: - WebSocket Methods
    
    private func sendAudio(pcmData: Data) {
        guard connectionState == .connected else { return }
        
        let base64Audio = pcmData.base64EncodedString()
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        send(event: event)
    }
    
    private func commitAudioBuffer() {
        logger.info("📤 Committing audio buffer")
        
        // Add placeholder user message to ensure correct ordering
        if pendingUserMessageId == nil {
            let userMessage = ChatMessage(isUser: true, text: "...")
            pendingUserMessageId = userMessage.id
            messages.append(userMessage)
        }
        
        let commitEvent: [String: String] = [
            "type": "input_audio_buffer.commit"
        ]
        send(event: commitEvent)
    }
    
    /// Request a response from the assistant
    private func requestResponse() {
        let responseEvent: [String: String] = [
            "type": "response.create"
        ]
        send(event: responseEvent)
    }
    
    /// Cancel current response (for barge-in)
    private func cancelResponse() {
        logger.info("🚫 Cancelling current response")
        let cancelEvent: [String: String] = [
            "type": "response.cancel"
        ]
        send(event: cancelEvent)
    }
    
    /// Stop audio playback immediately
    private func stopPlayback() {
        playerNode?.stop()
        // Clear any scheduled buffers by stopping and restarting
        playerNode?.play()
        // Note: pendingAudioBufferCount is reset by the caller when needed
        logger.info("🔇 Playback stopped")
    }
    
    /// Ask a fast LLM to determine if user expects a response
    private func shouldRespondToUser(_ transcript: String) async -> Bool {
        // Build context from recent conversation
        let context = recentTranscripts.suffix(maxRecentTranscripts).joined(separator: "\n")
        
        let prompt = """
            You are an intent classifier for a voice assistant. Analyze if the user has finished their thought and expects an AI response.
            
            Recent conversation context:
            \(context.isEmpty ? "(none)" : context)
            
            Current user utterance:
            \(transcript)
            
            Consider:
            - Did the user ask a question?
            - Did the user give a command or request?
            - Did the user say a trigger word like "answer", "respond", "done", "ответь", "готово"?
            - Is the sentence complete or does it seem like the user might continue?
            - A pause or "hmm" or "let me think" means user is still thinking - don't respond yet.
            
            Reply with ONLY one word: YES or NO
            YES = user expects a response now
            NO = user is still thinking or hasn't asked anything yet
            """
        
        do {
            let result = try await callFastLLM(prompt: prompt)
            let shouldRespond = result.uppercased().contains("YES")
            logger.info("🤖 Intent classifier: \(result) → shouldRespond: \(shouldRespond)")
            return shouldRespond
        } catch {
            logger.warning("⚠️ Intent classifier failed: \(error.localizedDescription), falling back to simple heuristics")
            // Fallback: check for question marks or common trigger phrases
            return transcript.contains("?") || 
                   transcript.lowercased().contains("ответь") ||
                   transcript.lowercased().contains("done") ||
                   transcript.lowercased().contains("answer")
        }
    }
    
    /// Call gpt-4o-mini for fast classification
    private func callFastLLM(prompt: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3 // Fast timeout - we need quick response
        
        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 10,
            "temperature": 0
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NSError(domain: "RealtimeAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "LLM request failed"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "RealtimeAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid LLM response"])
        }
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func configureSession() async {
        logger.info("Configuring session...")
        
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": """
                    You are a helpful voice assistant for smart glasses. Keep responses brief and conversational. 
                    Respond in the same language the user speaks.
                    Be natural and helpful. The user is wearing smart glasses and talking to you hands-free.
                    """,
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 2000,  // 2 seconds pause before detecting end of speech
                    "create_response": false       // Don't auto-respond, wait for trigger phrase
                ] as [String: Any]
            ]
        ]
        
        send(event: sessionConfig)
    }
    
    private func send(event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize event")
            return
        }
        
        webSocket?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                self?.logger.error("Send error: \(error.localizedDescription)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }
            
            Task { @MainActor in
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessage()
                    
                case .failure(let error):
                    // Ignore errors when we're already disconnected (expected on manual disconnect)
                    if self.connectionState != .disconnected {
                        self.logger.error("Receive error: \(error.localizedDescription)")
                        self.connectionState = .error(error.localizedDescription)
                    }
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseServerEvent(text)
            
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseServerEvent(text)
            }
            
        @unknown default:
            logger.warning("Unknown message type received")
        }
    }
    
    private func parseServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["type"] as? String else {
            logger.warning("Failed to parse server event")
            return
        }
        
        lastServerEvent = eventType
        
        switch eventType {
        case "session.created":
            connectionState = .connected
            logger.info("✅ Session created")
            
        case "session.updated":
            isSessionConfigured = true
            logger.info("✅ Session configured")
            
        case "response.created":
            logger.info("📝 New response started")
            // Clear transcript for new response
            assistantTranscript = ""
            isResponseActive = true
            assistantMessageFinalized = false
            responseGenerationComplete = false
            
        case "response.audio.delta":
            if let delta = json["delta"] as? String,
               let audioData = Data(base64Encoded: delta) {
                voiceState = .speaking
                playAudioData(audioData)
            }
            
        case "response.audio.done":
            logger.info("🔊 Audio response complete")
            
        case "response.audio_transcript.delta":
            if let delta = json["delta"] as? String {
                assistantTranscript += delta
            }
            
        case "response.audio_transcript.done":
            if let transcript = json["transcript"] as? String {
                // Only add message if not already finalized during barge-in
                if !assistantMessageFinalized {
                    messages.append(ChatMessage(isUser: false, text: transcript))
                    logger.info("🤖 Assistant: \(transcript)")
                } else {
                    logger.info("🤖 Assistant transcript received (already finalized during barge-in)")
                }
                // Clear for next response
                assistantTranscript = ""
            }
            
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                userTranscript = transcript
                // Update the placeholder message instead of adding new one
                if let pendingId = pendingUserMessageId,
                   let index = messages.firstIndex(where: { $0.id == pendingId }) {
                    messages[index].text = transcript
                    pendingUserMessageId = nil
                }
                logger.info("👤 User: \(transcript)")
                
                // Add to recent transcripts for context
                recentTranscripts.append(transcript)
                if recentTranscripts.count > maxRecentTranscripts {
                    recentTranscripts.removeFirst()
                }
                
                // Ask LLM classifier if we should respond
                Task {
                    let shouldRespond = await shouldRespondToUser(transcript)
                    if shouldRespond {
                        logger.info("🎯 LLM decided to respond")
                        requestResponse()
                    } else {
                        logger.info("⏸️ LLM decided to wait")
                        voiceState = .idle // Go back to idle, user might continue
                    }
                }
            }
            
        case "input_audio_buffer.speech_started":
            logger.info("🎙️ Speech started (VAD)")
            
            // Always stop any playing audio when user starts speaking
            // This handles the case where response.done was received but audio is still playing
            let wasPlaying = pendingAudioBufferCount > 0 || voiceState == .speaking || isResponseActive
            
            if wasPlaying {
                logger.info("🛑 Barge-in: stopping AI audio (pending buffers: \(self.pendingAudioBufferCount))")
                stopPlayback()
                pendingAudioBufferCount = 0
                
                if isResponseActive {
                    cancelResponse()
                    isResponseActive = false
                }
                
                // Finalize interrupted AI message before adding user placeholder
                // This ensures correct message order (AI message appears before user's interruption)
                if !assistantTranscript.isEmpty {
                    let interruptedText = assistantTranscript + "..."
                    messages.append(ChatMessage(isUser: false, text: interruptedText))
                    logger.info("🤖 Assistant (interrupted): \(interruptedText)")
                    assistantTranscript = ""
                    assistantMessageFinalized = true // Prevent duplicate from response.audio_transcript.done
                }
            }
            
            voiceState = .listening
            // Add placeholder for user message
            if pendingUserMessageId == nil {
                let userMessage = ChatMessage(isUser: true, text: "...")
                pendingUserMessageId = userMessage.id
                messages.append(userMessage)
            }
            
        case "input_audio_buffer.speech_stopped":
            logger.info("🔇 Speech stopped (VAD)")
            voiceState = .processing
            
        case "input_audio_buffer.committed":
            logger.info("📥 Audio buffer committed")
            
        case "response.done":
            logger.info("✅ Response generation complete")
            isResponseActive = false
            responseGenerationComplete = true
            
            // Only set idle if all audio buffers have finished playing
            if pendingAudioBufferCount <= 0 {
                voiceState = .idle
                logger.info("🔇 No pending audio buffers, going idle")
            } else {
                logger.info("⏳ Waiting for \(self.pendingAudioBufferCount) audio buffers to finish playing")
            }
            
        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                // Ignore cancellation errors - they're expected when barge-in happens after response completes
                if message.contains("Cancellation failed") || message.contains("no active response") {
                    logger.info("ℹ️ Cancellation skipped (response already completed)")
                } else {
                    logger.error("❌ Server error: \(message)")
                    connectionState = .error(message)
                    voiceState = .idle
                }
            }
            
        default:
            logger.debug("Event: \(eventType)")
        }
    }
}
