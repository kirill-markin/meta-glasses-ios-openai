# AI Glasses

iOS app for experimenting with Meta Ray-Ban smart glasses.

## Stack

- Swift 5 / SwiftUI
- Meta Wearables Device Access Toolkit (MWDATCore, MWDATCamera)
- Bluetooth LE for glasses connection

## SDK Documentation

### Meta Wearables
- GitHub: https://github.com/facebook/meta-wearables-dat-ios
- Developer Center: https://developer.meta.com/docs/wearables

### OpenAI Realtime API
- Docs: https://platform.openai.com/docs/guides/realtime
- WebSocket endpoint: `wss://api.openai.com/v1/realtime?model=gpt-realtime`
- Audio format: PCM16, 24kHz, mono

## Architecture

### Glasses Tab
- `GlassesManager` - singleton for glasses connection and streaming
- `ContentView` - TabView with Glasses and Voice Agent tabs
- `AudioManager` - Bluetooth HFP audio session for glasses mic
- `VideoRecorder` - records video frames with audio to file

### Voice Agent Tab
- `RealtimeAPIClient` - WebSocket client for OpenAI Realtime API with audio capture/playback
- `VoiceAgentView` - UI for voice conversations with OpenAI
- `Config` - API keys (gitignored)

## Key SDK Classes

- `Wearables.shared` - main entry point
- `AutoDeviceSelector` - automatic device selection
- `StreamSession` - video streaming and photo capture
- `VideoFrame.makeUIImage()` - convert frame to UIImage

## Requirements

- Physical iOS device (simulator doesn't support Bluetooth)
- Meta Ray-Ban AI glasses paired with device
- MetaAppID from https://developer.meta.com (add to Info.plist)
