//
//  MetaGlassesApp.swift
//  meta-glasses-ios-openai
//
//  Created by Kirill Markin on 03/01/2026.
//

import SwiftUI
import MWDATCore
import AppIntents
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "meta-glasses-ios-openai", category: "App")

@main
struct MetaGlassesApp: App {
    
    init() {
        logger.info("🚀 App starting...")
        do {
            try Wearables.configure()
            logger.info("✅ Wearables SDK configured")
        } catch {
            logger.error("❌ Failed to configure Wearables SDK: \(error.localizedDescription)")
            fatalError("Failed to configure Wearables SDK: \(error)")
        }
        
        // Register Siri Shortcuts for voice activation
        MetaGlassesShortcuts.updateAppShortcutParameters()
        logger.info("✅ Siri Shortcuts registered")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    logger.info("📲 Received URL callback: \(url.absoluteString)")
                    Task {
                        do {
                            _ = try await Wearables.shared.handleUrl(url)
                            logger.info("✅ URL handled successfully")
                        } catch {
                            logger.error("❌ Failed to handle URL: \(error.localizedDescription)")
                        }
                    }
                }
        }
    }
}
