# Relay: Private Messaging over MQTT with MLS

This repository contains the specification and reference implementation of **Relay**, an end-to-end encrypted messaging protocol that maps the Messaging Layer Security (MLS) protocol ([RFC 9420](https://datatracker.ietf.org/doc/html/rfc9420)) onto MQTT 5.0.

## Overview

Relay acts as the **Delivery Service** for MLS, providing:

- **End-to-end encryption** via MLS (forward secrecy, post-compromise security)
- **Asynchronous messaging** via KeyPackages (prekeys)
- **Standard MQTT 5.0** transport (works with any MQTT broker)
- **Minimal protocol surface** - just MLS messages over MQTT topics

### Architecture

```
┌───────────────────────────────────────────────────────┐
│                 Application Layer                     │
├───────────────────────────────────────────────────────┤
│             MLS Protocol (RFC 9420)                   │
│  (Key Agreement, Forward Secrecy, Auth, Group State)  │
├───────────────────────────────────────────────────────┤
│                 MQTT 5.0 Transport                    │
│         (Routing, Pub/Sub, Reliability)               │
└───────────────────────────────────────────────────────┘
```

## Repository Structure

- [protocol.md](protocol.md) - Relay protocol specification
- [relay-rs/](relay-rs/) - Reference implementation in Rust
- [relay-ios/](relay-ios/) - Native iOS client for the Relay protocol

## Protocol Topics

Relay uses the following MQTT topic structure:

| Topic | Purpose | QoS | Retain |
|-------|---------|-----|--------|
| `relay/k/{client_id}` | KeyPackages (prekeys) | 1 | true |
| `relay/w/{client_id}` | Welcome messages | 1 | false |
| `relay/g/{group_id}/m` | Group messages | 1 | false |
| `relay/g/{group_id}/i` | GroupInfo | 1 | true |

## Security Model

- **Broker is untrusted**: Confidentiality and integrity guaranteed by MLS
- **Content privacy**: All application messages encrypted via MLS PrivateMessage
- **Client-centric**: Uses client IDs per RFC 9750 MLS Architecture
- **Ordering**: MQTT broker provides message sequencing
- **Availability**: Best-effort via MQTT QoS 1

## Status

This is an **experimental protocol** for research and demonstration purposes. The specification and implementation are subject to change.

## License

See [LICENSE](./LICENSE) file for details.

## Contributing

Contributions are welcome! Please open an issue or pull request.

## References

- [RFC 9420: The Messaging Layer Security (MLS) Protocol](https://datatracker.ietf.org/doc/html/rfc9420)
- [RFC 9750: The Messaging Layer Security (MLS) Architecture](https://datatracker.ietf.org/doc/html/rfc9750)
- [MQTT Version 5.0](https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html)
- [OpenMLS Documentation](https://openmls.tech/)
