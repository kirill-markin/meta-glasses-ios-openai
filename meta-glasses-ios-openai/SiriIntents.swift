//
//  SiriIntents.swift
//  meta-glasses-ios-openai
//
//  Siri Shortcuts integration for Voice Agent
//

import AppIntents
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meta-glasses-ios-openai", category: "SiriIntents")

// MARK: - Voice Agent Trigger

/// Observable singleton that bridges Siri Intent and UI
/// When Siri triggers the intent, this flag is set to true
/// VoiceAgentView observes this and auto-connects
@MainActor
final class VoiceAgentTrigger: ObservableObject {
    static let shared = VoiceAgentTrigger()
    
    @Published var shouldStartVoiceAgent: Bool = false
    
    private init() {}
    
    /// Reset the trigger after handling
    func reset() {
        shouldStartVoiceAgent = false
    }
}

// MARK: - Start Voice Agent Intent

/// App Intent that starts the Voice Agent when triggered by Siri
struct StartVoiceAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Start AI Assistant"
    static let description = IntentDescription("Start a voice conversation with AI through your Meta Glasses")
    
    /// When true, the app will be launched/brought to foreground when this intent runs
    static let openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult {
        logger.info("🎙️ Siri triggered StartVoiceAgentIntent")
        VoiceAgentTrigger.shared.shouldStartVoiceAgent = true
        return .result()
    }
}

// MARK: - App Shortcuts Provider

/// Registers App Shortcuts with Siri
/// These phrases will be recognized by Siri even when the app is closed
struct MetaGlassesShortcuts: AppShortcutsProvider {
    
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVoiceAgentIntent(),
            phrases: [
                "Start session with \(.applicationName)",
            ],
            shortTitle: "Start AI Assistant",
            systemImageName: "waveform.circle"
        )
    }
}
