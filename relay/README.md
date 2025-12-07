# Relay Reference Client

A reference implementation of the Relay protocol (private messaging over MQTT with MLS) in Rust.

## Features

- **Full MLS implementation** using [OpenMLS 0.7.1](https://github.com/openmls/openmls)
- **Sealed Sender** encryption to hide metadata from MQTT broker
- **Proof-of-Work** mining for DoS protection (16-bit SHA-256 puzzle)
- **Asynchronous messaging** via MQTT with KeyPackage publishing
- **Interactive console chat** with multiple peers simultaneously

## Building

```bash
cargo build
```

## Running

You will need two separate terminal windows to test the chat.

### Terminal 1 (Client A):

```bash
cargo run
```

Copy the "My User ID" printed at the start (e.g., `1a2b3c4d...`).

### Terminal 2 (Client B):

```bash
cargo run
```

Copy Client B's ID.

## Usage

### Commands

- `info` - Display your User ID
- `connect <peer_id>` - Fetch peer's KeyPackage and prepare to chat
- `chat <peer_id> <message>` - Send an encrypted message to peer

### Chat Flow

1. **In Terminal 1 (Alice)**: Type `connect <CLIENT_B_ID>` (replace `<CLIENT_B_ID>` with the ID from Terminal 2)
   - Wait for the message "[System] Received keys for ..."

2. **In Terminal 1 (Alice)**: Type `chat <CLIENT_B_ID> Hello World`
   - Alice will:
     - Mine Proof-of-Work (shows progress)
     - Create MLS group and add Bob
     - Send Welcome message + Application message
   - Client B should see:
     - `--- Session Established ---`
     - `Hello World`

3. **In Terminal 2 (Bob)**: Type `chat <CLIENT_A_ID> Hi back!`
   - Bob will reply using the established MLS session
   - No PoW needed after session establishment (future optimization: Access Tokens)

## Architecture

The client implements the complete Relay stack:

```
┌─────────────────────────────────────┐
│     Interactive Console (stdin)      │
├─────────────────────────────────────┤
│      MLS Group Management            │
│   (OpenMLS - RFC 9420 compliance)   │
├─────────────────────────────────────┤
│         Relay Privacy Layer          │
│  • Sealed Sender (X25519+AES-GCM)   │
│  • Proof-of-Work (SHA-256 puzzle)   │
│  • RatchetTree serialization         │
├─────────────────────────────────────┤
│        MQTT 5.0 Client               │
│      (rumqttc, QoS 1, Retained)     │
└─────────────────────────────────────┘
```

## Implementation Details

### Key Components

1. **Identity Generation**
   - Random 128-bit User ID (hex-encoded)
   - Ed25519 signature keypair via OpenMLS
   - X25519 keypair for Sealed Sender outer encryption

2. **KeyPackage Publishing**
   - Wrapped in `MlsMessageOut` for wire format
   - Published to `relay/u/{user_id}/keys` with `retain=true`
   - Includes BasicCredential with User ID

3. **Message Flow**
   - Fetch peer's KeyPackage from `relay/u/{peer_id}/keys`
   - Create MLS group, add peer → generates Welcome
   - Serialize Welcome with RatchetTree (for out-of-band sync)
   - Encrypt in Sealed Envelope with PoW
   - Publish to `relay/u/{peer_id}/inbox`

4. **Session Management**
   - One MLS group per peer (P2P messaging)
   - Groups stored in HashMap by peer User ID
   - Automatic pending commit merging after add_members

5. **Cryptographic Operations**
   - **MLS**: Handled by OpenMLS (ciphersuite: MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519)
   - **Sealed Sender**: X25519 ECDH → HKDF-SHA256 → AES-256-GCM
   - **PoW**: SHA-256 hash with 16-bit difficulty (leading two zero bytes)

## Configuration

Default MQTT broker: `broker.emqx.io:1883`

To change the broker, edit the constants in `src/main.rs`:

```rust
const BROKER_HOST: &str = "broker.emqx.io";
const BROKER_PORT: u16 = 1883;
```

## Dependencies

Key dependencies:

- `openmls = "0.7.1"` - MLS protocol implementation
- `openmls_rust_crypto = "0.4.1"` - Crypto provider (RustCrypto primitives)
- `openmls_basic_credential = "0.4.1"` - Basic credential support
- `rumqttc = "0.24"` - Async MQTT 5.0 client
- `tokio = "1"` - Async runtime
- `curve25519-dalek = "4.1"` - X25519 for Sealed Sender
- `aes-gcm = "0.10"` - AES-256-GCM encryption
- `sha2 = "0.10"` - SHA-256 for PoW
- `ciborium = "0.2"` - CBOR serialization

See [`Cargo.toml`](Cargo.toml) for complete dependencies.

## Limitations & Future Work

- **Access Tokens**: Not implemented (PoW is always computed)
- **Group Messaging**: Not implemented
  - Current implementation uses MLS groups for 1:1 chats (following MLS patterns)
  - N-way groups (3+ members) need additional logic for group topic management
- **Storage**: In-memory only (ephemeral sessions, no persistence)
- **KeyPackage Rotation**: Not implemented (single KeyPackage per session)
- **Error Recovery**: Basic error handling, no sophisticated retry logic
- **Production Hardening**: This is a reference implementation for demonstration and research

## Protocol Specification

See [`../protocol.md`](../protocol.md) for the complete Relay protocol specification.

## Troubleshooting

### Connection Issues

If clients can't connect to the broker:
- Check internet connectivity
- Try a different public MQTT broker (e.g., `test.mosquitto.org`)
- Ensure firewall allows outbound TCP on port 1883

### "Unknown peer" Error

Ensure you run `connect <peer_id>` before sending messages. The client needs to fetch the peer's KeyPackage first.

### PoW Taking Too Long

PoW mining with 16-bit difficulty takes ~1-5 seconds on modern hardware. If it's taking significantly longer:
- Reduce difficulty in `seal_message()` function (change `hash[0] == 0 && hash[1] == 0` to just `hash[0] == 0`)
- Note: Lower difficulty = weaker DoS protection

## License

See LICENSE file in repository root.
