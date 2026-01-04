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
    
    /// Stop listening and trigger response
    func stopListening() {
        guard voiceState == .listening else { return }
        
        logger.info("🎤 Stopping listening...")
        stopAudioCapture()
        
        // Commit audio buffer to signal end of speech
        commitAudioBuffer()
        
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
        guard let audioEngine = audioEngine, let playerNode = playerNode else {
            logger.warning("⚠️ Cannot play audio: engine not running")
            return
        }
        
        // Create buffer from PCM16 data
        let frameCount = data.count / 2 // 2 bytes per sample
        
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: openAISampleRate,
            channels: openAIChannels,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            logger.error("❌ Failed to create playback buffer")
            return
        }
        
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        // Convert Int16 to Float32
        data.withUnsafeBytes { rawBuffer in
            let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
            guard let floatData = buffer.floatChannelData?[0] else { return }
            
            for i in 0..<frameCount {
                floatData[i] = Float(int16Ptr[i]) / Float(Int16.max)
            }
        }
        
        // Convert sample rate if needed
        let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        
        if format.sampleRate != outputFormat.sampleRate {
            guard let converter = AVAudioConverter(from: format, to: outputFormat) else {
                logger.error("❌ Failed to create playback converter")
                return
            }
            
            let outputFrameCount = AVAudioFrameCount(
                Double(frameCount) * outputFormat.sampleRate / format.sampleRate
            )
            
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputFrameCount) else {
                return
            }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
            
            if error == nil {
                playerNode.scheduleBuffer(outputBuffer)
            }
        } else {
            playerNode.scheduleBuffer(buffer)
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
        let event: [String: String] = [
            "type": "input_audio_buffer.commit"
        ]
        send(event: event)
    }
    
    private func configureSession() async {
        logger.info("Configuring session...")
        
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": "You are a helpful voice assistant for smart glasses. Keep responses brief and conversational. Respond in the same language the user speaks.",
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
                    "silence_duration_ms": 800
                ]
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
                    self.logger.error("Receive error: \(error.localizedDescription)")
                    self.connectionState = .error(error.localizedDescription)
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
            
        case "input_audio_buffer.speech_started":
            logger.info("🎤 Speech started (VAD detected)")
            voiceState = .listening
            
        case "input_audio_buffer.speech_stopped":
            logger.info("🎤 Speech stopped (VAD detected)")
            voiceState = .processing
            
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
                assistantTranscript = transcript
                logger.info("🤖 Assistant: \(transcript)")
            }
            
        case "conversation.item.input_audio_transcription.completed":
            if let transcript = json["transcript"] as? String {
                userTranscript = transcript
                logger.info("👤 User: \(transcript)")
            }
            
        case "response.done":
            logger.info("✅ Response complete")
            voiceState = .idle
            
        case "error":
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                logger.error("❌ Server error: \(message)")
                connectionState = .error(message)
                voiceState = .idle
            }
            
        default:
            logger.debug("Event: \(eventType)")
        }
    }
}
