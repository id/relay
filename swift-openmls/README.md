# swift-openmls

Swift bindings for OpenMLS - Rust implementation of the Messaging Layer Security (MLS) protocol.

## Overview

This package provides Swift bindings to OpenMLS using UniFFI, enabling end-to-end encrypted group messaging in iOS apps using the MLS protocol (RFC 9420).

## Features

- Client identity generation with Ed25519 signatures
- KeyPackage creation and management
- MLS group creation and joining
- Adding members to groups
- Encrypting and decrypting messages
- Native Swift types via UniFFI

## Prerequisites

### Install Rust
```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
```

### Add iOS Targets
```bash
rustup target add aarch64-apple-ios           # iOS devices (arm64)
rustup target add aarch64-apple-ios-sim       # iOS Simulator (M1/M2 Macs)
rustup target add x86_64-apple-ios            # iOS Simulator (Intel Macs)
```

### Install cargo-swift
```bash
cargo install cargo-swift
```

## Building

### 1. Build the Swift Package

From the `swift-openmls` directory:

```bash
cargo swift package -p ios -n SwiftOpenMLS
```

This generates a Swift Package in `SwiftOpenMLS/` containing:
- XCFramework with compiled Rust code for all iOS architectures
- Swift bindings with native types
- `Package.swift` for Swift Package Manager

### 2. Optional: Build for Specific Targets

For development, you can build for specific targets:

```bash
# Build for iOS Simulator (Apple Silicon)
cargo build --target aarch64-apple-ios-sim

# Build for iOS Simulator (Intel)
cargo build --target x86_64-apple-ios

# Build for iOS Device
cargo build --target aarch64-apple-ios --release
```

## Integration with Xcode

### Method 1: Local Package (Recommended for Development)

1. Build the package: `cargo swift package -p ios -n SwiftOpenMLS`
2. In Xcode: **File → Add Package Dependencies...**
3. Click **Add Local...** and select the `SwiftOpenMLS/` folder
4. Import in Swift: `import SwiftOpenMLS`

### Method 2: Copy XCFramework (Alternative)

1. Build for all targets
2. Create XCFramework manually
3. Drag into Xcode project

## Usage Example

```swift
import SwiftOpenMLS

// Generate client identity
let identity = try generateClientIdentity(clientId: "alice-client-123")
print("Generated client: \(identity.clientId)")

// Create a KeyPackage
let keyPackage = try createKeyPackage(clientId: identity.clientId)
print("KeyPackage hash: \(keyPackage.keyPackageHash.hexString)")

// Create a new group
let group = try OpenMlsGroup(groupId: "group-abc", clientId: identity.clientId)
print("Created group: \(group.groupId())")

// Add a member
let result = try group.addMember(keyPackageBytes: peerKeyPackage)
// Send result.welcomeBytes to the new member
// Broadcast result.commitBytes to existing members

// Encrypt a message
let plaintext = "Hello, MLS!".data(using: .utf8)!
let ciphertext = try group.encrypt(plaintext: Array(plaintext))
// Publish ciphertext to group topic

// Decrypt a message
let decrypted = try group.decrypt(ciphertextBytes: receivedCiphertext)
let message = String(data: Data(decrypted.plaintext), encoding: .utf8)!
print("Received: \(message) from \(decrypted.senderClientId)")
```

## API Reference

### Functions

#### `generateClientIdentity(clientId: String) -> ClientIdentity`
Generate a new client identity with credential and signature keypair.

**Returns:**
- `clientId`: The client identifier
- `credentialBytes`: Serialized MLS credential
- `signaturePublicKey`: Ed25519 public key

#### `createKeyPackage(clientId: String) -> KeyPackageBundle`
Create a KeyPackage for the client.

**Returns:**
- `keyPackageBytes`: Serialized KeyPackage
- `keyPackageHash`: Hash of the KeyPackage

### OpenMlsGroup

#### `init(groupId: String, clientId: String)`
Create a new MLS group as the creator.

#### `init(joinFromWelcome: Data, clientId: String)`
Join an existing group from a Welcome message.

#### `addMember(keyPackageBytes: [UInt8]) -> AddMemberResult`
Add a new member to the group.

**Returns:**
- `welcomeBytes`: Send this to the new member
- `commitBytes`: Broadcast this to existing members

#### `encrypt(plaintext: [UInt8]) -> [UInt8]`
Encrypt an application message.

#### `decrypt(ciphertextBytes: [UInt8]) -> DecryptedMessage`
Decrypt a received message.

**Returns:**
- `plaintext`: Decrypted message bytes
- `senderClientId`: ID of the sender

#### `groupId() -> String`
Get the group ID as a hex string.

#### `members() -> [String]`
Get list of member client IDs.

## Ciphersuite

The library uses:
- **Ciphersuite**: `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`
- **Key Exchange**: X25519
- **AEAD**: AES-128-GCM
- **Hash**: SHA-256
- **Signature**: Ed25519

## Architecture

```
Swift App
    ↓
SwiftOpenMLS (Swift bindings via UniFFI)
    ↓
swift-openmls (Rust crate)
    ↓
OpenMLS (Rust MLS implementation)
    ↓
openmls_rust_crypto (Cryptographic backend)
```

## Development

### Testing the Build

```bash
# Check if it compiles
cargo build

# Run Rust tests
cargo test

# Build for iOS
cargo swift package -p ios -n SwiftOpenMLS
```

### Updating Bindings

After modifying `src/lib.rs`:

1. Rebuild the package: `cargo swift package -p ios -n SwiftOpenMLS`
2. In Xcode: **File → Packages → Update to Latest Package Versions**

### Cleaning Build Artifacts

```bash
cargo clean
rm -rf SwiftOpenMLS/
```

## Known Issues & TODO

- [ ] Proper signer persistence (currently uses placeholder key references)
- [ ] Extract sender client ID from decrypted messages
- [ ] Group state serialization/deserialization
- [ ] External commit support for recovery
- [ ] Proper error handling for all OpenMLS operations
- [ ] Add member removal functionality
- [ ] Group info and tree synchronization

## Dependencies

- [OpenMLS](https://github.com/openmls/openmls) v0.6 - MLS protocol implementation
- [UniFFI](https://github.com/mozilla/uniffi-rs) v0.28 - Rust-to-Swift bindings
- [cargo-swift](https://github.com/antoniusnaumann/cargo-swift) - Build tool for iOS

## Resources

- [MLS RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html)
- [OpenMLS Book](https://openmls.tech/book/)
- [UniFFI User Guide](https://mozilla.github.io/uniffi-rs/)
- [Relay Protocol](../protocol.md)

## License

See [LICENSE](../LICENSE) in the repository root.
