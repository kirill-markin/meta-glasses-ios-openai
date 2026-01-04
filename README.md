# Meta Glasses iOS OpenAI

![Meta Glasses AI Screenshots](docs/screenshots.png)

Voice AI assistant for **Meta smart glasses** powered by **OpenAI Realtime API**.

Talk hands-free through your glasses. The AI hears you, sees what you see, and responds in natural voice.

## Features

- 🎙️ **Voice conversations** — talk naturally through glasses mic, hear responses in speakers
- 💬 **Conversation history** — browse and continue past discussions

**Tools** the AI can use:
- 📷 `take_photo` — see through glasses camera ("what am I looking at?")
- 🌐 `search_internet` — real-time news, weather, prices, sports scores (via Perplexity)
- 🧠 `manage_memory` — remember things about you across conversations

## Before You Start

> ⚠️ **Developer Mode Required**  
> Your Meta glasses must have **Developer Mode enabled** before this app can connect to them.  
> Without this, the app will build successfully but won't see your glasses.
>
> **How to enable:**  
> 1. Open **Meta AI** app on your phone  
> 2. Go to **Settings** → **Glasses** → scroll down  
> 3. Enable **Developer Mode**  
> 4. Follow prompts to restart glasses if needed
>
> See [Meta Wearables Setup Guide](https://wearables.developer.meta.com/docs/getting-started-toolkit) for detailed instructions.

## Quick Start

### 1. Clone and configure

```bash
git clone https://github.com/kirill-markin/meta-glasses-ios-openai.git
cd meta-glasses-ios-openai

# Copy config templates
cp Config.xcconfig.example Config.xcconfig
cp meta-glasses-ios-openai/Config.swift.example meta-glasses-ios-openai/Config.swift
```

### 2. Fill in credentials

The project requires two config files (both are gitignored for security):

| Required file | Example template |
|---------------|------------------|
| `Config.xcconfig` | [`Config.xcconfig.example`](Config.xcconfig.example) |
| `meta-glasses-ios-openai/Config.swift` | [`Config.swift.example`](meta-glasses-ios-openai/Config.swift.example) |

Copy each `.example` file (remove the `.example` suffix) and fill in your values:

**Config.xcconfig** — Xcode build settings:
```
PRODUCT_BUNDLE_IDENTIFIER = com.yourcompany.metaglasses
DEVELOPMENT_TEAM = YOUR_TEAM_ID_HERE
META_APP_ID = YOUR_META_APP_ID_HERE
```

**Config.swift** — API keys:
```swift
static let openAIAPIKey = "sk-..."
static let perplexityAPIKey = "pplx-..."
```

### 3. Build and run

Open `meta-glasses-ios-openai.xcodeproj` in Xcode → Run on physical iOS device.

> ⚠️ Simulator won't work — Bluetooth is required for glasses connection.

## Requirements

| What | Where to get |
|------|--------------|
| Physical iOS device | — |
| Meta smart glasses | Paired via Meta AI app |
| Meta App ID | [developer.meta.com](https://developer.meta.com) |
| OpenAI API key | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| Perplexity API key | [perplexity.ai/settings/api](https://www.perplexity.ai/settings/api) |

> 💡 Don't forget to enable Developer Mode on your glasses — see [Before You Start](#before-you-start) above.

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

[MIT](LICENSE)

## Author

**Kirill Markin** — [github.com/kirill-markin](https://github.com/kirill-markin)
