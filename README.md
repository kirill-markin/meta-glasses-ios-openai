# Meta Glasses iOS OpenAI

![Meta Glasses AI Screenshots](docs/screenshots.png)

Voice AI assistant for **Meta Ray-Ban smart glasses** powered by **OpenAI Realtime API**.

Talk hands-free through your glasses. The AI hears you, sees what you see, and responds in natural voice.

## Features

- 🎙️ **Voice conversations** — talk naturally through glasses mic, hear responses in speakers
- 💬 **Conversation history** — browse and continue past discussions

**Tools** the AI can use:
- 📷 `take_photo` — see through glasses camera ("what am I looking at?")
- 🌐 `search_internet` — real-time news, weather, prices, sports scores
- 🧠 `manage_memory` — remember things about you across conversations

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/nicekurt/meta-glasses-ios-openai.git
cd meta-glasses-ios-openai

# Copy config templates
cp Config.xcconfig.example Config.xcconfig
cp meta-glasses-ios-openai/Config.swift.example meta-glasses-ios-openai/Config.swift
```

### 2. Fill in credentials

**Config.xcconfig:**
```
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.metaglasses
DEVELOPMENT_TEAM = YOUR_TEAM_ID_HERE
META_APP_ID = YOUR_META_APP_ID_HERE
```

**Config.swift:**
```swift
static let openAIAPIKey = "sk-..."
```

### 3. Build and run

Open `meta-glasses-ios-openai.xcodeproj` in Xcode → Run on physical iOS device.

> ⚠️ Simulator won't work — Bluetooth is required for glasses connection.

## Requirements

| What | Where to get |
|------|--------------|
| Physical iOS device | — |
| Meta Ray-Ban smart glasses | Paired via Meta View app |
| Meta App ID | [developer.meta.com](https://developer.meta.com) |
| OpenAI API key | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |

## Tech Stack

- Swift 5 / SwiftUI
- [Meta Wearables SDK](https://github.com/facebook/meta-wearables-dat-ios) (MWDATCore, MWDATCamera)
- [OpenAI Realtime API](https://platform.openai.com/docs/guides/realtime) (WebSocket)
- Bluetooth HFP for glasses audio

## Project Structure

```
meta-glasses-ios-openai/
├── VoiceAgentView.swift    # Main voice UI
├── RealtimeAPIClient.swift # OpenAI WebSocket + audio
├── GlassesManager.swift    # Meta SDK integration
├── ThreadsManager.swift    # Conversation history
├── SettingsManager.swift   # User prompt & memories
└── AudioManager.swift      # Bluetooth HFP audio
```

## License

MIT

## Author

**Kirill Markin** — [github.com/nicekurt](https://github.com/nicekurt)
