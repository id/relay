# Relay iOS

Native iOS client for the Relay protocol - a secure messaging system that maps MLS (Messaging Layer Security) onto MQTT 5.0 for end-to-end encrypted communication.

## Features

### Current (Phase 0: Core MQTT + Basic UI)
- MQTT 5.0 client with TLS support
- Subscribe to multiple topics (with wildcard support: `+`, `#`)
- Separate publish/subscribe topics per conversation
- Real-time message sending and receiving
- Persistent conversations with SwiftData
- Connection management and status monitoring
- Configurable MQTT brokers
- Two modes: Relay (encrypted) and Raw MQTT

### Coming Soon (Phase 1: OpenMLS)
- MLS group creation and management
- End-to-end encryption using OpenMLS
- Key package distribution
- Member add/remove operations

## Requirements

- iOS 18.0+
- Xcode 16.0+
- Swift 6.0+

## Getting Started

### 1. Open Project
```bash
open relay-ios/Relay.xcodeproj
```

### 2. Dependencies
The project uses Swift Package Manager. Dependencies will be fetched automatically:
- [swift-mqtt](https://github.com/emqx/swift-mqtt) - MQTT 5.0 client

### 3. Build & Run
1. Select a simulator or device
2. Press `Cmd+R` to build and run
3. Choose your app mode on first launch (Relay or Raw MQTT)

## Project Structure

```
relay-ios/
├── Relay/
│   ├── RelayApp.swift           # App entry point
│   ├── Models/                  # SwiftData models
│   │   ├── BrokerConfig.swift   # MQTT broker configuration
│   │   ├── Conversation.swift   # Chat conversations
│   │   └── Message.swift        # Individual messages
│   ├── Services/
│   │   └── MQTTService.swift    # MQTT connection & pub/sub
│   └── Views/
│       ├── Onboarding/          # First-launch setup
│       ├── Conversations/       # Message list
│       ├── Chat/                # Chat interface
│       └── Settings/            # App settings & broker config
```

## Usage

### Creating a Conversation
1. Tap the compose button in the Messages tab
2. Add one or more **subscribe topics** (supports wildcards):
   - `chat/alice` - exact topic
   - `chat/+` - single-level wildcard (matches `chat/alice`, `chat/bob`)
   - `chat/#` - multi-level wildcard (matches `chat/alice/room1`, `chat/bob/room2`)
3. Set a **publish topic** (leave empty to use first subscribe topic)
4. Optionally set a display name (defaults to first subscribe topic)
5. Tap Create

### Managing Topics
- Tap the info button in a chat to view/edit topics
- Add new subscribe topics on the fly
- Remove topics by swiping left
- Edit publish topic using the pencil icon above message input

### Configuring MQTT Broker
1. Go to Settings tab
2. Tap the broker entry to edit
3. Configure:
   - Host (e.g., `broker.emqx.io`)
   - Port (default: `8883` for TLS)
   - TLS enabled/disabled
   - Optional username/password

Default broker: `broker.emqx.io:8883` (TLS)

## MQTT Wildcards

- **`+`** - Single-level wildcard
  - `chat/+/messages` matches `chat/alice/messages` but not `chat/alice/room1/messages`
- **`#`** - Multi-level wildcard
  - `chat/#` matches `chat/alice`, `chat/alice/messages`, `chat/alice/room1/status`
  - Must be the last character in a topic filter

## Architecture Notes

### Models
- **SwiftData** for persistence (SQLite backend)
- **@Observable** macro for reactive state management
- Automatic schema migration handling during development

### MQTT Service
- Built on `swift-mqtt` library
- Supports MQTT 5.0 protocol
- TLS/TCP connections
- QoS levels: at most once, at least once, exactly once
- Automatic reconnection handling

### UI
- **SwiftUI** with iOS 18 features
- Navigation stack for deep linking
- Sheet presentations for modal flows

## Development

### Database Reset
If you encounter schema migration errors after model changes:
1. Delete the app from simulator/device, OR
2. The app will automatically detect and reset the database

### Known Issues
- Message deduplication not implemented (you may see your own messages twice)
- No message persistence across app restarts yet
- Wildcard subscribe topics may match your own published messages

## License

See [LICENSE](../LICENSE) in the repository root.
