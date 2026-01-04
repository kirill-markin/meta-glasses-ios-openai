# AI Glasses

iOS app for experimenting with Meta smart glasses.

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

## Architecture

### App Structure
- `ContentView` - TabView with Voice Agent, Threads, and Settings tabs
- `GlassesManager` - singleton for glasses connection and streaming
- `GlassesTab` - glasses UI, accessed via Settings → Hardware → Glasses
- `AudioManager` - Bluetooth HFP audio session for glasses mic
- `VideoRecorder` - records video frames with audio to file

### Voice Agent Tab
- `RealtimeAPIClient` - WebSocket client for OpenAI Realtime API with audio capture/playback
- `VoiceAgentView` - UI for voice conversations with OpenAI
- `Config` - API keys (copy `Config.swift.example` → `Config.swift`)

### Threads Tab
- `ThreadsManager` - singleton for conversation history persistence to Documents/threads.json
- `ThreadsView` - UI for browsing past conversations
- Continue discussion: resumes thread via `conversation.item.create` to populate history

### Settings Tab
- `SettingsManager` - singleton for settings persistence to Documents/settings.json
- `SettingsView` - UI for editing user prompt and memories
- User prompt: additional instructions appended to system prompt
- Memories: key-value pairs the AI can read and manage
- Live updates: changes to settings send `session.update` to active session (debounced 500ms)

### Voice Agent Features
- Server VAD + LLM intent classifier (gpt-4o-mini) decides when to respond
- Tool: `take_photo` - AI can capture photos from glasses during conversation
- Tool: `manage_memory` - AI can store/update/delete memories about the user
- Barge-in: user can interrupt AI while speaking

### Audio
- OpenAI format: PCM16, 24kHz, mono
- HFP (Hands-Free Profile) for glasses Bluetooth mic
- Auto-conversion between device and OpenAI formats

### Media Persistence
- Files saved to Documents directory
- Metadata in `captured_media.json`
- Auto-save to Photo Library

## Key SDK Classes

- `Wearables.shared` - main entry point
- `AutoDeviceSelector` - automatic device selection
- `StreamSession` - video streaming and photo capture
- `VideoFrame.makeUIImage()` - convert frame to UIImage

## Key Patterns

- `@MainActor` isolation for GlassesManager, RealtimeAPIClient
- LazyView for deferred VoiceAgentView initialization
- Listener tokens retained for SDK stream subscriptions

## Requirements

- Physical iOS device (simulator doesn't support Bluetooth)
- Meta AI glasses paired with device
- MetaAppID from https://developer.meta.com (add to Info.plist)
