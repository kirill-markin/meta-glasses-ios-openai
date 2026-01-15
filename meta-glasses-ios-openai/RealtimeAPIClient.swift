//
//  RealtimeAPIClient.swift
//  meta-glasses-ios-openai
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
    @Published private(set) var isMuted: Bool = false
    
    // MARK: - Private Properties
    
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var sessionDelegate: WebSocketDelegate?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meta-glasses-ios-openai", category: "RealtimeAPI")
    
    private let realtimeURL = Constants.realtimeAPIURL
    
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
    
    // Audio interruption observer for background handling
    private var interruptionObserver: NSObjectProtocol?
    
    // Glasses manager for photo capture
    private let glassesManager: GlassesManager
    
    // Track pending function call for tool handling
    private var pendingFunctionCallId: String?
    private var pendingFunctionName: String?
    
    // Track pending tool message for updating with result
    private var pendingToolMessageId: UUID?
    
    // Settings observer for live updates
    private var settingsSubscription: AnyCancellable?
    
    // Thread ID for continuation (if resuming existing thread)
    private var continuationThreadId: UUID?
    private var historyToLoad: [StoredMessage] = []
    
    // Base system instructions (without user customizations)
    private var baseInstructions: String {
        var instructions = """
        You are a helpful voice assistant integrated into Meta smart glasses. 
        
        # Context
        - The user is wearing Meta AI glasses with a built-in camera
        - You hear the user through the glasses microphone
        - The user hears your responses through the glasses speakers
        - This is a hands-free, eyes-up experience - keep responses concise
        
        # Capabilities
        - You have access to the glasses camera via the take_photo tool
        - When the user asks what they're looking at, seeing, or wants visual information about their surroundings, use the take_photo tool
        - The tool will capture a photo and provide you with a description of what the camera sees
        - You can store and manage memories about the user via the manage_memory tool
        - Use manage_memory when the user shares personal info, preferences, or asks you to remember something
        """
        
        // Only include search_internet if Perplexity is configured
        if SettingsManager.shared.isPerplexityConfigured {
            instructions += """
            
            - You can search the internet via the search_internet tool
            - Use search_internet when the user asks about current events, news, weather, prices, stock quotes, sports scores, or any question requiring real-time up-to-date information
            """
        }
        
        instructions += """
        
        
        # Guidelines
        - Keep responses brief and conversational (1-3 sentences when possible) if user is not asking for longer responses.
        - Respond in the same language the user speaks
        - Be natural, helpful, and context-aware
        - When describing what the user sees, be specific and helpful
        """
        
        if SettingsManager.shared.isPerplexityConfigured {
            instructions += """
            
            - When providing search results, summarize the key information concisely
            """
        }
        
        instructions += """
        
        
        # Communication Style
        - Use a Business Casual tone - professional yet approachable
        - Be slightly informal and friendly with the user, like a helpful colleague
        - Avoid being overly formal or robotic - keep it warm and personable
        - Feel free to use casual expressions when appropriate
        
        # Voice Personality
        - Speak with genuine enthusiasm and positive energy
        - Sound like you're smiling when you talk - warm, bright, and engaged
        - Express curiosity and delight when helping the user
        - Use an upbeat, lively tone without being over-the-top
        - Show authentic interest in what the user is asking about
        - When the user shares something cool, match their excitement
        - Avoid monotone or flat delivery - vary your intonation naturally
        """
        
        return instructions
    }
    
    /// Generate current time and location context string
    private func generateContextInfo() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone.current
        
        var context = "\n\nCurrent time: \(formatter.string(from: Date()))"
        
        if let location = LocationManager.shared.locationString {
            context += "\nUser location: \(location)"
        }
        
        return context
    }
    
    // MARK: - Initialization
    
    init(glassesManager: GlassesManager) {
        self.glassesManager = glassesManager
        setupAudioInterruptionHandling()
        setupSettingsObserver()
    }
    
    deinit {
        // Remove audio interruption observer
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Cancel settings subscription
        settingsSubscription?.cancel()
        // Clean up audio engine synchronously
        audioEngine?.inputNode.removeTap(onBus: 0)
        playerNode?.stop()
        audioEngine?.stop()
    }
    
    /// Set up observer for settings changes to update instructions live
    private func setupSettingsObserver() {
        settingsSubscription = SettingsManager.shared.$settings
            .dropFirst() // Skip initial value (we configure on connect)
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main) // Debounce rapid changes
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sendInstructionsUpdate()
                }
            }
    }
    
    /// Send updated instructions to the active session
    private func sendInstructionsUpdate() {
        guard connectionState == .connected, isSessionConfigured else {
            logger.debug("Skipping instructions update - not connected or not configured")
            return
        }
        
        let systemInstructions = baseInstructions + generateContextInfo() + ThreadsManager.shared.generateConversationHistoryContext() + SettingsManager.shared.generateInstructionsAddendum()
        
        let updateEvent: [String: Any] = [
            "type": "session.update",
            "session": [
                "instructions": systemInstructions
            ] as [String: Any]
        ]
        
        send(event: updateEvent)
        logger.info("📝 Sent instructions update with latest settings")
    }
    
    /// Set up handling for audio session interruptions (calls, other apps, etc.)
    private func setupAudioInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract Sendable values before crossing isolation boundary
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(typeValue: typeValue, optionsValue: optionsValue)
            }
        }
    }
    
    private func handleAudioInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue = typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            logger.warning("⚠️ Audio session interrupted (call, other app, etc.)")
            if voiceState == .speaking {
                stopPlayback()
                pendingAudioBufferCount = 0
            }
            
        case .ended:
            logger.info("✅ Audio session interruption ended")
            if let optionsValue = optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    do {
                        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                        logger.info("✅ Audio session reactivated after interruption")
                    } catch {
                        logger.error("❌ Failed to reactivate audio session: \(error.localizedDescription)")
                    }
                }
            }
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Public Methods
    
    /// Connect to Realtime API
    /// - Parameter threadId: Optional thread ID to resume an existing conversation
    func connect(threadId: UUID? = nil) {
        guard connectionState == .disconnected || connectionState != .connecting else {
            logger.warning("Already connecting or connected")
            return
        }
        
        // Request location update if permission already granted (don't trigger system dialog)
        LocationManager.shared.requestLocation()
        
        connectionState = .connecting
        logger.info("Connecting to Realtime API...")
        
        // Handle thread: resume existing or create new
        if let threadId = threadId,
           let history = ThreadsManager.shared.resumeThread(id: threadId) {
            continuationThreadId = threadId
            historyToLoad = history
            // Pre-populate messages array with history for UI
            messages = history.map { stored in
                ChatMessage(isUser: stored.isUser, text: stored.text)
            }
            logger.info("📜 Will continue thread \(threadId) with \(history.count) messages")
        } else {
            continuationThreadId = nil
            historyToLoad = []
            // Create a new thread for this conversation
            _ = ThreadsManager.shared.createThread()
        }
        
        // Also connect to glasses if registered
        if glassesManager.isRegistered && !glassesManager.connectionState.isConnected {
            logger.info("👓 Auto-connecting to glasses...")
            glassesManager.startSearching()
        }
        
        guard let url = URL(string: realtimeURL) else {
            connectionState = .error("Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(SettingsManager.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        // Create delegate to capture connection errors
        sessionDelegate = WebSocketDelegate { [weak self] error in
            Task { @MainActor in
                guard let self = self, self.connectionState == .connecting else { return }
                self.connectionState = .error(error)
            }
        }
        
        urlSession = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
        webSocket = urlSession?.webSocketTask(with: request)
        webSocket?.resume()
        
        // Start receiving messages
        receiveMessage()
        
        // Connection timeout - if not connected within 10 seconds, show error
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if connectionState == .connecting {
                connectionState = .error("Connection timeout. Check your API key and network connection.")
                disconnect()
            }
        }
        
        // Configure session after connection
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await configureSession()
        }
    }
    
    func disconnect() {
        logger.info("Disconnecting from Realtime API")
        
        // Play disconnect sound
        SoundManager.shared.playDisconnectSound()
        
        // Save messages to thread before clearing
        ThreadsManager.shared.saveMessages(messages: messages)
        ThreadsManager.shared.finalizeActiveThread()
        
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
        isMuted = false
        continuationThreadId = nil
        historyToLoad = []
        
        // Also disconnect from glasses
        if glassesManager.connectionState.isConnected {
            logger.info("👓 Auto-disconnecting from glasses...")
            glassesManager.disconnect()
        }
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
    
    /// Toggle microphone mute state
    /// Simple behavior: just stop/resume sending audio, no side effects
    func toggleMute() {
        isMuted.toggle()
        logger.info("🎤 Microphone \(self.isMuted ? "muted" : "unmuted")")
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
            Task { @MainActor [weak self] in
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
        
        // When muted, send silence instead of actual audio
        // This keeps the audio stream continuous so VAD can properly detect pauses
        let audioToSend: Data
        if isMuted {
            audioToSend = Data(count: pcmData.count) // Zero-filled buffer = silence
        } else {
            audioToSend = pcmData
        }
        
        let base64Audio = audioToSend.base64EncodedString()
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
            You are an intent classifier for a voice assistant in Meta smart glasses with a camera.
            
            The assistant can:
            - Answer questions
            - Take photos and describe what the user sees
            - Have natural conversations
            
            Recent conversation:
            \(context.isEmpty ? "(start of conversation)" : context)
            
            User just said:
            "\(transcript)"
            
            Should the assistant respond NOW?
            
            Answer YES if:
            - User asked ANY question (has "?" or question words like what/how/why/where)
            - User asked to see/look/describe something (visual request)
            - User gave a command or request
            - User greeted AND asked something ("Hi, what is this?" = YES)
            - The utterance is a complete thought that warrants a response
            
            Answer NO only if:
            - User is clearly mid-sentence and paused (e.g., "I want to..." or "I need to...")
            - User said filler words only (e.g., "hmm", "let me think", "uh", "well")
            - User is talking to someone else (not the assistant)
            
            DEFAULT TO YES when uncertain. Questions always get YES.
            
            Reply with ONLY: YES or NO
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
                   transcript.lowercased().contains("respond") ||
                   transcript.lowercased().contains("done") ||
                   transcript.lowercased().contains("answer")
        }
    }
    
    /// Call fast model (Constants.fastModel) for classification
    private func callFastLLM(prompt: String) async throws -> String {
        let url = URL(string: Constants.openAIChatCompletionsURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(SettingsManager.shared.openAIAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3 // Fast timeout - we need quick response
        
        let body: [String: Any] = [
            "model": Constants.fastModel,
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
    
    /// Call Perplexity Search API for web search
    private func callPerplexitySearch(query: String) async throws -> String {
        let url = URL(string: Constants.perplexitySearchURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(SettingsManager.shared.perplexityAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        
        let body: [String: Any] = [
            "query": query,
            "max_results": 5,
            "max_tokens_per_page": 1024
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "RealtimeAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "RealtimeAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Perplexity API error (\(httpResponse.statusCode)): \(errorMessage)"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            throw NSError(domain: "RealtimeAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Perplexity response format"])
        }
        
        // Format results for the AI
        var formattedResults = "Search results for: \(query)\n\n"
        
        for (index, result) in results.enumerated() {
            let title = result["title"] as? String ?? "No title"
            let snippet = result["snippet"] as? String ?? "No content"
            let url = result["url"] as? String ?? ""
            let date = result["date"] as? String
            
            formattedResults += "[\(index + 1)] \(title)\n"
            if let date = date {
                formattedResults += "Date: \(date)\n"
            }
            formattedResults += "\(snippet)\n"
            formattedResults += "Source: \(url)\n\n"
        }
        
        if results.isEmpty {
            formattedResults = "No search results found for: \(query)"
        }
        
        return formattedResults
    }
    
    /// Get user-friendly display text for tool call
    private func toolCallDisplayText(name: String) -> String {
        switch name {
        case "take_photo":
            return "📸 Capturing photo..."
        case "manage_memory":
            return "🧠 Managing memory..."
        case "search_internet":
            return "🔍 Searching the web..."
        default:
            return "🔧 \(name)..."
        }
    }
    
    /// Update the pending tool message with result text
    private func updatePendingToolMessage(text: String) {
        if let messageId = pendingToolMessageId,
           let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].text = text
        }
        pendingToolMessageId = nil
    }
    
    /// Handle function calls from the assistant
    private func handleFunctionCall(name: String, callId: String, arguments: String) async {
        logger.info("🔧 Handling function call: \(name)")
        
        switch name {
        case "take_photo":
            await handleTakePhotoTool(callId: callId)
        case "manage_memory":
            handleManageMemoryTool(callId: callId, arguments: arguments)
        case "search_internet":
            await handleSearchInternetTool(callId: callId, arguments: arguments)
        default:
            logger.warning("⚠️ Unknown function: \(name)")
            sendToolResult(callId: callId, result: "Error: Unknown function '\(name)'")
        }
    }
    
    /// Handle the manage_memory tool call
    private func handleManageMemoryTool(callId: String, arguments: String) {
        logger.info("🧠 Managing memory...")
        
        // Parse arguments
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["key"] as? String else {
            logger.error("❌ Failed to parse manage_memory arguments")
            updatePendingToolMessage(text: "🧠 Memory error")
            sendToolResult(callId: callId, result: "Error: Invalid arguments")
            return
        }
        
        let value = json["value"] as? String ?? ""
        
        // Perform the memory operation
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let previousValue = SettingsManager.shared.memories[trimmedKey]
        SettingsManager.shared.manageMemory(key: trimmedKey, value: trimmedValue)
        
        // Determine what happened and update chat message
        let displayMessage: String
        let resultMessage: String
        if trimmedValue.isEmpty {
            if previousValue != nil {
                displayMessage = "🧠 Deleted: \(trimmedKey)"
                resultMessage = "Memory '\(trimmedKey)' deleted."
                logger.info("🧠 Deleted memory: \(trimmedKey)")
            } else {
                displayMessage = "🧠 Not found: \(trimmedKey)"
                resultMessage = "Memory '\(trimmedKey)' was not found."
                logger.info("🧠 Memory not found for deletion: \(trimmedKey)")
            }
        } else if previousValue != nil {
            displayMessage = "🧠 Updated: \(trimmedKey)"
            resultMessage = "Memory '\(trimmedKey)' updated to: \(trimmedValue)"
            logger.info("🧠 Updated memory: \(trimmedKey) = \(trimmedValue)")
        } else {
            displayMessage = "🧠 Saved: \(trimmedKey)"
            resultMessage = "Memory '\(trimmedKey)' saved: \(trimmedValue)"
            logger.info("🧠 Added memory: \(trimmedKey) = \(trimmedValue)")
        }
        
        updatePendingToolMessage(text: displayMessage)
        sendToolResult(callId: callId, result: resultMessage)
    }
    
    /// Handle the search_internet tool call
    private func handleSearchInternetTool(callId: String, arguments: String) async {
        logger.info("🔍 Searching the internet...")
        
        // Parse arguments
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? String else {
            logger.error("❌ Failed to parse search_internet arguments")
            updatePendingToolMessage(text: "🔍 Search error")
            sendToolResult(callId: callId, result: "Error: Invalid arguments - missing query")
            return
        }
        
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            logger.error("❌ Empty search query")
            updatePendingToolMessage(text: "🔍 Search error")
            sendToolResult(callId: callId, result: "Error: Empty search query")
            return
        }
        
        do {
            let results = try await callPerplexitySearch(query: trimmedQuery)
            logger.info("🔍 Search completed successfully")
            updatePendingToolMessage(text: "🔍 Found results")
            sendToolResult(callId: callId, result: results)
        } catch {
            logger.error("❌ Search failed: \(error.localizedDescription)")
            updatePendingToolMessage(text: "🔍 Search failed")
            sendToolResult(callId: callId, result: "Search failed: \(error.localizedDescription)")
        }
    }
    
    /// Handle the take_photo tool call
    private func handleTakePhotoTool(callId: String) async {
        logger.info("📸 Taking photo for assistant...")
        
        do {
            // Capture photo using GlassesManager
            let photoData = try await capturePhotoFromGlasses()
            
            logger.info("📸 Photo captured, sending directly to Realtime API (\(photoData.count) bytes)")
            
            // Update the tool message with success
            updatePendingToolMessage(text: "📸 Photo captured")
            
            // Send the image directly to Realtime API as a conversation item
            sendImageToConversation(imageData: photoData)
            
            // Send tool result confirming the photo was taken
            sendToolResult(callId: callId, result: "Photo captured successfully. I can now see what the user is looking at.")
            
        } catch {
            logger.error("❌ Photo capture failed: \(error.localizedDescription)")
            
            // Update the tool message with error
            updatePendingToolMessage(text: "📸 Photo capture failed")
            
            sendToolResult(callId: callId, result: "Failed to capture photo: \(error.localizedDescription)")
        }
    }
    
    /// Send an image directly to the Realtime API conversation
    private func sendImageToConversation(imageData: Data) {
        let base64Image = imageData.base64EncodedString()
        
        let imageEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_image",
                        "image_url": "data:image/jpeg;base64,\(base64Image)"
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
        
        send(event: imageEvent)
        logger.info("📸 Image sent to Realtime API conversation")
    }
    
    /// Capture a photo from the glasses and return the image data
    /// Uses unified capturePhotoAsync() which also saves to Photo Library and Captured Media
    private func capturePhotoFromGlasses() async throws -> Data {
        // Check if glasses are registered
        let isRegistered = await MainActor.run { glassesManager.isRegistered }
        guard isRegistered else {
            throw NSError(
                domain: "RealtimeAPI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Glasses not registered. Please register in the Glasses tab first."]
            )
        }
        
        // Check if glasses are connected, try to connect if not
        let isConnected = await MainActor.run { glassesManager.connectionState.isConnected }
        if !isConnected {
            logger.info("👓 Glasses not connected, attempting to connect...")
            await MainActor.run { glassesManager.startSearching() }
            
            // Wait a bit for connection
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            
            // Check again after waiting
            let isConnectedNow = await MainActor.run { glassesManager.connectionState.isConnected }
            if !isConnectedNow {
                throw NSError(
                    domain: "RealtimeAPI",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not connect to glasses. Make sure they are nearby and powered on."]
                )
            }
        }
        
        // Use unified capture method that saves to Photo Library and Captured Media
        return try await glassesManager.capturePhotoAsync()
    }
    
    /// Send tool result back to the Realtime API
    private func sendToolResult(callId: String, result: String) {
        logger.info("📤 Sending tool result for call: \(callId)")
        
        // Create conversation item with tool result
        let itemEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "function_call_output",
                "call_id": callId,
                "output": result
            ] as [String: Any]
        ]
        send(event: itemEvent)
        
        // Request a new response that uses the tool result
        let responseEvent: [String: Any] = [
            "type": "response.create"
        ]
        send(event: responseEvent)
        
        // Clear pending function call state
        pendingFunctionCallId = nil
        pendingFunctionName = nil
    }
    
    private func configureSession() async {
        logger.info("Configuring session...")
        
        // Append time context, conversation history, user memories, and additional instructions from settings
        let systemInstructions = baseInstructions + generateContextInfo() + ThreadsManager.shared.generateConversationHistoryContext() + SettingsManager.shared.generateInstructionsAddendum()
        
        let takePhotoTool: [String: Any] = [
            "type": "function",
            "name": "take_photo",
            "description": "Capture a photo from the user's smart glasses camera. Use this when the user asks about what they are seeing, looking at, or wants visual information about their surroundings. Examples: 'What am I looking at?', 'What's in front of me?', 'Can you see this?', 'What is this?', 'Describe what you see'.",
            "parameters": [
                "type": "object",
                "properties": [:] as [String: Any],
                "required": [] as [String]
            ] as [String: Any]
        ]
        
        let manageMemoryTool: [String: Any] = [
            "type": "function",
            "name": "manage_memory",
            "description": "Store or update a memory about the user. Use when user shares personal info, preferences, or asks to remember something. Pass empty value to delete a memory.",
            "parameters": [
                "type": "object",
                "properties": [
                    "key": [
                        "type": "string",
                        "description": "Memory identifier in snake_case (e.g. 'user_name', 'preferred_language', 'favorite_food')"
                    ] as [String: Any],
                    "value": [
                        "type": "string",
                        "description": "Value to store. Pass empty string to delete the memory."
                    ] as [String: Any]
                ] as [String: Any],
                "required": ["key", "value"]
            ] as [String: Any]
        ]
        
        // Build tools array - search_internet is only available if Perplexity is configured
        var tools: [[String: Any]] = [takePhotoTool, manageMemoryTool]
        
        if SettingsManager.shared.isPerplexityConfigured {
            let searchInternetTool: [String: Any] = [
                "type": "function",
                "name": "search_internet",
                "description": "Search the internet for real-time information. Use when user asks about current events, news, weather, prices, sports scores, stock prices, or any question requiring up-to-date information from the web.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search query in natural language, one sentence"
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["query"]
                ] as [String: Any]
            ]
            tools.append(searchInternetTool)
            logger.info("🔍 search_internet tool enabled (Perplexity configured)")
        } else {
            logger.info("🔍 search_internet tool disabled (Perplexity not configured)")
        }
        
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": systemInstructions,
                "voice": Constants.realtimeVoice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": Constants.whisperModel
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": NSDecimalNumber(string: "0.8"),  // Higher threshold to filter out speaker echo while still detecting direct speech
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 2000,
                    "create_response": false
                ] as [String: Any],
                "tools": tools
            ] as [String: Any]
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
    
    /// Send conversation history to populate context when resuming a thread
    private func sendConversationHistory(_ history: [StoredMessage]) {
        logger.info("📜 Sending \(history.count) messages as conversation history")
        
        for message in history {
            // For conversation.item.create: user uses "input_text", assistant uses "text"
            let contentType = message.isUser ? "input_text" : "text"
            let role = message.isUser ? "user" : "assistant"
            
            let event: [String: Any] = [
                "type": "conversation.item.create",
                "item": [
                    "type": "message",
                    "role": role,
                    "content": [
                        [
                            "type": contentType,
                            "text": message.text
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ]
            
            send(event: event)
        }
        
        logger.info("📜 Conversation history sent")
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
                    guard self.connectionState != .disconnected else { return }
                    
                    // Don't overwrite a specific error message with generic socket error
                    // (e.g., server sent "Incorrect API key" then socket closed)
                    if case .error(_) = self.connectionState {
                        self.logger.info("Socket closed after error was already set, ignoring: \(error.localizedDescription)")
                        return
                    }
                    
                    self.logger.error("Receive error: \(error.localizedDescription)")
                    
                    // Parse error for more meaningful message
                    let nsError = error as NSError
                    let errorDesc = error.localizedDescription.lowercased()
                    var errorMessage = error.localizedDescription
                    
                    // Check for specific WebSocket/HTTP errors
                    if nsError.domain == "NSPOSIXErrorDomain" && nsError.code == 57 {
                        // Socket not connected - likely auth failure if we were still connecting
                        if self.connectionState == .connecting {
                            errorMessage = "Authentication failed. Check your OpenAI API key in Settings → AI → Models"
                        } else {
                            errorMessage = "Connection lost. Check your network."
                        }
                    } else if errorDesc.contains("401") || errorDesc.contains("unauthorized") || errorDesc.contains("invalid api key") {
                        errorMessage = "Invalid API key. Check Settings → AI → Models → OpenAI"
                    } else if errorDesc.contains("403") || errorDesc.contains("forbidden") {
                        errorMessage = "API key doesn't have Realtime API access"
                    } else if errorDesc.contains("429") || errorDesc.contains("rate limit") {
                        errorMessage = "Rate limit exceeded. Please wait and try again."
                    } else if errorDesc.contains("socket is not connected") || errorDesc.contains("not connected") {
                        // Generic socket error during connection = likely auth issue
                        if self.connectionState == .connecting {
                            errorMessage = "Connection rejected. Verify your OpenAI API key is valid and has Realtime API access."
                        } else {
                            errorMessage = "Connection lost unexpectedly."
                        }
                    }
                    
                    self.connectionState = .error(errorMessage)
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
            
            // Load conversation history if continuing a thread
            if !historyToLoad.isEmpty {
                sendConversationHistory(historyToLoad)
                historyToLoad = []
            }
            
            // Auto-start listening after initial session configuration (not on settings updates)
            if voiceState == .idle {
                startListening()
                SoundManager.shared.playReadySound()
            }
            
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
                    // Save messages to thread
                    ThreadsManager.shared.saveMessages(messages: messages)
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
                    // Save messages to thread
                    ThreadsManager.shared.saveMessages(messages: messages)
                }
                logger.info("👤 User: \(transcript)")
                
                // Check for stop phrases to end the conversation (case-insensitive)
                let stopPhrases = ["Stop session"]
                let lowerTranscript = transcript.lowercased()
                if stopPhrases.contains(where: { lowerTranscript.contains($0.lowercased()) }) {
                    logger.info("🛑 Stop phrase detected - disconnecting")
                    disconnect()
                    return
                }
                
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
                    // Save messages to thread
                    ThreadsManager.shared.saveMessages(messages: messages)
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
            
        case "response.output_item.added":
            // Check if this is a function call item
            if let item = json["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "function_call",
               let callId = item["call_id"] as? String,
               let name = item["name"] as? String {
                logger.info("🔧 Function call started: \(name) (id: \(callId))")
                pendingFunctionCallId = callId
                pendingFunctionName = name
                
                // Play sound and show message immediately when tool call starts
                SoundManager.shared.playToolCallSound()
                let toolMessage = ChatMessage(isUser: false, text: toolCallDisplayText(name: name))
                messages.append(toolMessage)
                pendingToolMessageId = toolMessage.id
            }
            
        case "response.function_call_arguments.done":
            logger.info("🔧 Function call arguments complete")
            // Sound and message already shown in response.output_item.added
            if let callId = json["call_id"] as? String,
               let name = json["name"] as? String {
                Task {
                    await handleFunctionCall(name: name, callId: callId, arguments: json["arguments"] as? String ?? "{}")
                }
            }
            
        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                // Ignore cancellation errors - they're expected when barge-in happens after response completes
                if message.contains("Cancellation failed") || message.contains("no active response") {
                    logger.info("ℹ️ Cancellation skipped (response already completed)")
                // Ignore buffer too small errors - expected when disconnecting without speaking
                } else if message.contains("buffer too small") {
                    logger.info("ℹ️ Empty audio buffer commit skipped (no speech detected)")
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

// MARK: - WebSocket Delegate

/// Delegate to capture WebSocket connection errors (e.g., authentication failures)
private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    private let onError: (String) -> Void
    private var errorAlreadyReported = false
    
    init(onError: @escaping (String) -> Void) {
        self.onError = onError
    }
    
    private func reportError(_ message: String) {
        // Only report first error - subsequent errors are usually cascading effects
        guard !errorAlreadyReported else { return }
        errorAlreadyReported = true
        onError(message)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // Extract meaningful error message
            let nsError = error as NSError
            let errorDesc = error.localizedDescription.lowercased()
            var errorMessage = error.localizedDescription
            
            // Check for HTTP response status code if available
            if let httpResponse = (task as? URLSessionWebSocketTask)?.response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 401:
                    errorMessage = "Invalid API key. Check Settings → AI → Models → OpenAI"
                    reportError(errorMessage)
                    return
                case 403:
                    errorMessage = "API key doesn't have Realtime API access. Verify permissions at platform.openai.com"
                    reportError(errorMessage)
                    return
                case 429:
                    errorMessage = "Rate limit exceeded. Please wait and try again."
                    reportError(errorMessage)
                    return
                case 500...599:
                    errorMessage = "OpenAI server error. Please try again later."
                    reportError(errorMessage)
                    return
                default:
                    break
                }
            }
            
            // Check for specific error codes
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorNotConnectedToInternet:
                    errorMessage = "No internet connection"
                case NSURLErrorTimedOut:
                    errorMessage = "Connection timed out"
                case NSURLErrorCannotConnectToHost:
                    errorMessage = "Cannot connect to OpenAI servers"
                case NSURLErrorUserAuthenticationRequired:
                    errorMessage = "Invalid API key. Check Settings → AI → Models → OpenAI"
                default:
                    // Check error description for auth hints
                    if errorDesc.contains("401") || errorDesc.contains("unauthorized") {
                        errorMessage = "Invalid API key. Check Settings → AI → Models → OpenAI"
                    }
                }
            } else if nsError.domain == "NSPOSIXErrorDomain" && nsError.code == 57 {
                // Socket not connected - often indicates auth failure during handshake
                errorMessage = "Connection failed. Verify your OpenAI API key is valid."
            }
            
            reportError(errorMessage)
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        var errorMessage = "Connection closed"
        
        // Parse close reason if available - OpenAI often includes error details here
        if let reason = reason, let reasonString = String(data: reason, encoding: .utf8), !reasonString.isEmpty {
            // Try to parse as JSON for structured error
            if let json = try? JSONSerialization.jsonObject(with: reason) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                errorMessage = message
            } else {
                errorMessage = reasonString
            }
        } else {
            // Map close codes to human-readable messages
            switch closeCode {
            case .invalid:
                errorMessage = "Invalid connection"
            case .policyViolation:
                errorMessage = "Authentication failed. Check your OpenAI API key."
            case .internalServerError:
                errorMessage = "OpenAI server error. Please try again later."
            case .normalClosure:
                // Normal closure - don't report as error
                return
            default:
                errorMessage = "Connection closed unexpectedly (code: \(closeCode.rawValue))"
            }
        }
        
        reportError(errorMessage)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
