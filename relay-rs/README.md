# Relay Reference Client

A minimal reference implementation of the Relay protocol (MLS over MQTT) in Rust.

## Overview

This implementation is designed for **clarity and portability**. It demonstrates the core Relay protocol concepts in ~450 lines of straightforward Rust code that can be easily translated to other languages.

## Building

```bash
cargo build --release
```

## Running

Open two terminals to test peer-to-peer messaging.

**Terminal 1:**
```bash
cargo run
```
Copy the Client ID displayed.

**Terminal 2:**
```bash
cargo run
```
Copy this Client ID too.

## Commands

| Command | Description |
|---------|-------------|
| `info` | Display your Client ID |
| `peers` | List active sessions and available KeyPackages |
| `connect <peer_id>` | Establish an encrypted session with a peer |
| `chat <peer_id> <message>` | Send an encrypted message |
| `quit` | Exit the client |

## Example Session

**Terminal 1 (Alice):**
```
Client ID: a1b2c3d4...
> connect e5f6g7h8...
[14:32:15] Connecting to e5f6g7h8...
[14:32:15] Session established with e5f6g7h8...
> chat e5f6g7h8 Hello Bob!
[14:32:20] <you> Hello Bob!
[14:32:25] <e5f6g7h8...> Hi Alice!
```

**Terminal 2 (Bob):**
```
Client ID: e5f6g7h8...
[14:32:15] Session established with a1b2c3d4...
[14:32:15] Use 'chat a1b2c3d4... <message>' to reply
[14:32:20] <a1b2c3d4...> Hello Bob!
> chat a1b2c3d4 Hi Alice!
[14:32:25] <you> Hi Alice!
```

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                     RelayClient                          │
├──────────────────────────────────────────────────────────┤
│  MLS Layer (OpenMLS)                                     │
│  - KeyPackage generation                                 │
│  - Group creation / Welcome processing                   │
│  - Message encryption / decryption                       │
├──────────────────────────────────────────────────────────┤
│  MQTT Layer (rumqttc)                                    │
│  - relay/k/{client_id}  → KeyPackages (retained)         │
│  - relay/w/{client_id}  → Welcome messages               │
│  - relay/g/{group_id}/m → Group messages                 │
│  - relay/g/{group_id}/i → GroupInfo (retained)           │
└──────────────────────────────────────────────────────────┘
```

## Dependencies

| Crate | Purpose |
|-------|---------|
| `openmls` | MLS protocol implementation |
| `openmls_rust_crypto` | Cryptographic backend |
| `openmls_basic_credential` | Basic credential support |
| `rumqttc` | MQTT client |
| `tls_codec` | MLS wire format serialization |
| `ciborium` | CBOR for KeyPackage arrays |
| `chrono` | Timestamps for logging |
| `hex` | Hex encoding for IDs |
| `anyhow` | Error handling |
| `rand` | Random number generation |

## Limitations

- **1:1 chats only**: N-way groups need additional UI/command support
- **In-memory state**: No persistence across restarts
- **Single KeyPackage**: No rotation implemented
- **Reference only**: Not production-hardened

## Protocol Specification

See [protocol.md](../protocol.md) for the complete Relay protocol specification.

## License

See [LICENSE](../LICENSE) file in repository root.
