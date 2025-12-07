# Relay: Private Messaging over MQTT with MLS

This repository contains the specification and reference implementation of **Relay**, an end-to-end encrypted messaging protocol that maps the Messaging Layer Security (MLS) protocol ([RFC 9420](https://datatracker.ietf.org/doc/html/rfc9420)) onto MQTT 5.0.

## Overview

Relay acts as the **Delivery Service** for MLS, providing:

- **End-to-end encryption** via MLS (forward secrecy, post-compromise security)
- **Metadata protection** via Sealed Sender (hides sender identity from broker)
- **Asynchronous messaging** via KeyPackages (prekeys)
- **DoS protection** via Proof-of-Work for unsolicited messages
- **Standard MQTT 5.0** transport (works with any MQTT broker)

### Architecture

```
+-------------------------------------------------------+
|                 Application Layer                     |
+-------------------------------------------------------+
|           MLS Protocol (RFC 9420)                     |
|  (Key Agreement, Forward Secrecy, Auth, Group State)  |
+-------------------------------------------------------+
|               Relay Privacy Layer                     |
|  (Sealed Sender, Proof-of-Work, Metadata Protection)  |
+-------------------------------------------------------+
|               MQTT 5.0 (Transport)                    |
|       (Routing, Pub/Sub, Reliability, Queuing)        |
+-------------------------------------------------------+
```

## Repository Structure

- **[`protocol.md`](protocol.md)** - Relay protocol specification
- **[`relay/`](relay/)** - Reference implementation in Rust

## Quick Start

```bash
cd relay
cargo run
```

See [relay/README.md](relay/README.md) for detailed usage instructions.

## Protocol Topics

Relay uses the following MQTT topic structure:

| Topic | Purpose | QoS | Retain |
|-------|---------|-----|--------|
| `relay/u/{user_id}/inbox` | Private messages & group invites | 1 | false |
| `relay/u/{user_id}/keys` | Published KeyPackages (prekeys) | 1 | true |
| `relay/g/{group_id}/m` | Group messages | 1 | false |

## Security Model

- **Broker is untrusted**: Confidentiality and integrity guaranteed by MLS + Sealed Sender
- **Content privacy**: MLS encryption
- **Metadata privacy**: Sealed Sender hides sender from broker
- **Ordering**: MQTT broker provides message sequencing
- **Availability**: Best-effort via MQTT QoS 1

## Dependencies

The reference implementation uses:

- [Rust](https://www.rust-lang.org/) (2021 edition)
- [OpenMLS](https://github.com/openmls/openmls) - MLS protocol implementation
- [rumqttc](https://github.com/bytebeamio/rumqtt) - MQTT 5.0 client
- [curve25519-dalek](https://github.com/dalek-cryptography/curve25519-dalek) - Sealed Sender crypto
- Standard Rust crypto crates (aes-gcm, hkdf, sha2)

## Status

This is an **experimental protocol** for research and demonstration purposes. The specification and implementation are subject to change.

## License

See LICENSE file for details.

## Contributing

Contributions are welcome! Please open an issue or pull request.

## References

- [RFC 9420: The Messaging Layer Security (MLS) Protocol](https://datatracker.ietf.org/doc/html/rfc9420)
- [MQTT Version 5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html)
- [OpenMLS Documentation](https://openmls.tech/)
