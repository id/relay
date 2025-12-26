# RFC: Relay Protocol - MLS over MQTT

## Abstract

This document specifies the Relay protocol, which maps the Messaging Layer Security (MLS) protocol [RFC 9420] onto MQTT 5.0 [MQTT-5.0]. Relay implements the Delivery Service role for MLS, providing asynchronous message delivery and KeyPackage distribution over an untrusted MQTT broker.

This specification follows the MLS Architecture [RFC 9750] recommendations for building secure group messaging systems.

## Status of This Memo

This document specifies an Experimental protocol for the Internet community.

## Table of Contents

1. Introduction
   - 1.1. Design Goals
   - 1.2. Relationship to MLS
2. Conventions and Definitions
3. Architecture Overview
   - 3.1. Clients and Users
   - 3.2. Abstract Services
4. Topic Structure
   - 4.1. Client Topics
   - 4.2. Group Topics
5. Wire Format
6. Client Identity and KeyPackages
   - 6.1. Client Identity
   - 6.2. KeyPackage Publication
   - 6.3. KeyPackage Consumption
   - 6.4. Last Resort KeyPackages
7. User Identity (Application Layer)
   - 7.1. User-Client Binding
   - 7.2. User Discovery
   - 7.3. Adding Users to Groups
   - 7.4. Verifying User Identity
8. Group Lifecycle
   - 8.1. Creating a Group
   - 8.2. Joining via Welcome
   - 8.3. Joining via External Commit
   - 8.4. Sending Messages
   - 8.5. Receiving Messages
   - 8.6. Adding Members
   - 8.7. Removing Members
   - 8.8. Updating Keys
9. State Synchronization
   - 9.1. Prevention
   - 9.2. Detection
   - 9.3. Recovery
10. Operational Considerations
    - 10.1. Transport Security
    - 10.2. Message Ordering
    - 10.3. Access Control
    - 10.4. Credential Management
    - 10.5. Idle Client Eviction
11. Security Considerations
    - 11.1. Trust Model
    - 11.2. Metadata Privacy
    - 11.3. DoS Considerations
12. IANA Considerations
13. References
Appendix A. Design Rationale

## 1. Introduction

The Messaging Layer Security (MLS) protocol [RFC 9420] provides end-to-end encrypted group messaging with strong security properties including forward secrecy and post-compromise security. MLS defines the cryptographic protocol but relies on an abstract Delivery Service (DS) for message routing and key distribution.

Relay specifies how to implement the MLS Delivery Service using MQTT 5.0, a widely deployed publish/subscribe protocol. The mapping is intentionally minimal, using native MLS message formats wherever possible.

### 1.1. Design Goals

*   **Minimal DS Implementation**: Implement only what MLS requires from a Delivery Service.
*   **Native MLS Framing**: Use `MLSMessage` wire format directly, without custom wrappers.
*   **Standard MQTT 5.0**: Use retained messages for KeyPackages and QoS 1 for delivery.
*   **Asynchronous Operation**: Support offline clients via KeyPackages and message queuing.
*   **Client-Centric**: Follow MLS's client model; user identity is an application-layer concern.

### 1.2. Relationship to MLS

Relay implements the Delivery Service (DS) role as defined in [RFC 9750] Section 5:

> "The Delivery Service (DS) plays two major roles in MLS: as a directory service, providing the initial keying material for clients to use [...] and routing MLS messages among clients."

Relay does NOT implement the Authentication Service (AS) role. Credential issuance and validation are delegated to the application layer.

## 2. Conventions and Definitions

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in BCP 14 [RFC 2119] [RFC 8174].

This document uses terminology from [RFC 9420] and [RFC 9750]:

*   **Client**: A set of cryptographic keys and state representing a single device or application instance. The basic unit of operation in MLS.
*   **User**: A human or logical entity that may control one or more clients. User identity is an application-layer concept.
*   **Member**: A client that is part of an MLS group.
*   **Group**: An MLS group. MLS uses groups for all messaging, including two-party "groups" for 1:1 messaging.
*   **KeyPackage**: Initial keying material published by a client to enable asynchronous group joins.
*   **Credential**: An assertion binding an identity to a signature key, contained in a KeyPackage.

## 3. Architecture Overview

### 3.1. Clients and Users

Following [RFC 9750] Section 3.7:

> "In MLS the basic unit of operation is not the user but rather the 'client'. [...] a user may have multiple clients with the same identity and different keys."

Relay operates at the **client** level. Each client:
*   Has a unique `client_id` (128-bit random identifier).
*   Publishes its own KeyPackages.
*   Maintains independent MLS group state.
*   Receives its own Welcome messages.

The **user** concept (e.g., "Alice has a phone and laptop") is handled at the application layer. Section 7 provides recommendations for implementing user-level abstractions.

### 3.2. Abstract Services

```
+-------------------+     +-------------------+
| Authentication    |     | Delivery Service  |
| Service (AS)      |     | (MQTT + Relay)    |
| [Application]     |     |                   |
+-------------------+     +--------+----------+
                                   |
          +------------------------+------------------------+
          |                        |                        |
    +-----+-----+            +-----+-----+            +-----+-----+
    | Client 1  |            | Client 2  |            | Client 3  |
    | (Phone)   |            | (Laptop)  |            | (Tablet)  |
    +-----------+            +-----------+            +-----------+
          \__ User: Alice __/                               |
                                                      User: Bob
```

*   **Authentication Service (AS)**: Application-provided. Issues and validates credentials.
*   **Delivery Service (DS)**: Implemented by Relay over MQTT. Routes messages and stores KeyPackages.

## 4. Topic Structure

All Relay topics are prefixed with `relay/`.

### 4.1. Client Topics

| Resource | Topic | Purpose | QoS | Retain |
| :--- | :--- | :--- | :--- | :--- |
| KeyPackages | `relay/k/{client_id}` | KeyPackage discovery | 1 | `true` |
| Welcome | `relay/w/{client_id}` | Welcome messages | 1 | `false` |

*   `{client_id}`: Hex-encoded 128-bit random identifier (32 characters).

### 4.2. Group Topics

| Resource | Topic | Purpose | QoS | Retain |
| :--- | :--- | :--- | :--- | :--- |
| Messages | `relay/g/{group_id}/m` | PrivateMessage, Commits | 1 | `false` |
| GroupInfo | `relay/g/{group_id}/i` | GroupInfo for External Joins | 1 | `true` |

*   `{group_id}`: Hex-encoded 16-byte random identifier (32 characters), generated at group creation.

## 5. Wire Format

Relay uses native MLS wire formats exclusively. All messages are `MLSMessage` structs as defined in [RFC 9420] Section 6:

```
struct {
    ProtocolVersion version = mls10;
    WireFormat wire_format;
    select (MLSMessage.wire_format) {
        case mls_public_message:  PublicMessage;
        case mls_private_message: PrivateMessage;
        case mls_welcome:         Welcome;
        case mls_group_info:      GroupInfo;
        case mls_key_package:     KeyPackage;
    };
} MLSMessage;
```

**Topic to Message Type Mapping**:

| Topic | Expected `wire_format` |
| :--- | :--- |
| `relay/k/{client_id}` | Array of `mls_key_package` |
| `relay/w/{client_id}` | `mls_welcome` |
| `relay/g/{group_id}/m` | `mls_private_message`, `mls_public_message` |
| `relay/g/{group_id}/i` | `mls_group_info` |

**KeyPackage Array Format**: KeyPackages are published as a CBOR array of serialized `MLSMessage` bytes:

```
KeyPackageArray = [* bstr]  ; Array of MLSMessage (KeyPackage)
```

## 6. Client Identity and KeyPackages

### 6.1. Client Identity

Each client generates a random 128-bit `client_id` on first launch. This identifier:
*   MUST be unique across all clients.
*   MUST be stable for the lifetime of the client.
*   Is used for MQTT topic addressing, not for cryptographic identity.

Cryptographic identity is established via the MLS credential in the client's KeyPackages.

### 6.2. KeyPackage Publication

Clients MUST publish KeyPackages to enable asynchronous group joins.

**Requirements**:
*   Publish to `relay/k/{client_id}` with `RETAIN = true`.
*   Include multiple KeyPackages (RECOMMENDED: 10-100) to support concurrent joins.
*   Each KeyPackage MUST have a unique `init_key`.
*   KeyPackages MUST include a `lifetime` extension indicating validity period.
*   KeyPackages SHOULD be refreshed weekly or when the bundle is depleted.

**Credential**: KeyPackages contain an MLS credential binding identity to a signature key. Relay supports any MLS credential type; the choice is application-specific.

> *Recommendation* [RFC 9750 Section 8.4.2]: "Prefer a credential type in KeyPackages which includes a strong cryptographic binding between the identity and its key (for example, the x509 credential type)."

### 6.3. KeyPackage Consumption

When adding a client to a group:

1.  Fetch the KeyPackage array from `relay/k/{client_id}`.
2.  Validate each KeyPackage's credential per application policy.
3.  Select ONE KeyPackage at random from valid KeyPackages.
4.  Use it to create the MLS Welcome message.
5.  Do NOT reuse a KeyPackage for multiple groups.

**Replay Protection**: Clients MUST track consumed KeyPackage hashes and reject Welcome messages reusing a KeyPackage. The tracking set MAY be pruned after the KeyPackage's `lifetime` expires.

### 6.4. Last Resort KeyPackages

Following [RFC 9750] Section 5.1, clients SHOULD designate one KeyPackage as a "last resort" that can be reused if all others are consumed:

> *Recommendation*: "Ensure that 'last resort' KeyPackages don't get used by provisioning enough standard KeyPackages."

> *Recommendation*: "Rotate 'last resort' KeyPackages as soon as possible after being used."

If a last resort KeyPackage is used, the client SHOULD immediately:
1.  Publish fresh KeyPackages.
2.  Perform a key update in any groups joined via the last resort KeyPackage.

**Init Key Deletion**: Clients MUST delete the private component of `init_key` after processing a Welcome message.

## 7. User Identity (Application Layer)

While Relay operates at the client level, applications typically present a user-level abstraction. This section provides recommendations for implementing user identity.

### 7.1. User-Client Binding

A **user** is a logical entity (typically a person) that controls one or more **clients** (devices).

**Option A: Shared Credential Identity**

All clients belonging to a user include the same `identity` value in their MLS credentials:

```
BasicCredential {
    identity: "user:alice@example.com"  // Same for all of Alice's clients
}
```

The credential signature keys differ per client, but the identity string is shared. This allows group members to recognize that multiple clients belong to the same user.

**Option B: User Directory Service**

The application maintains a mapping from user identifiers to client identifiers:

```
GET /users/alice/clients
→ ["client_abc123...", "client_def456..."]
```

This is more flexible but requires additional infrastructure.

**Option C: Credential Hierarchy**

Use X.509 credentials where a user certificate signs per-device certificates:

```
User CA (alice@example.com)
  └── Client cert (alice-phone)
  └── Client cert (alice-laptop)
```

Group members can verify that client credentials chain to the same user CA.

### 7.2. User Discovery

To start a group with a user, the initiator needs to discover the user's clients:

1.  **Out-of-Band**: User shares their client IDs directly (e.g., QR code, contact card).
2.  **Directory Service**: Application provides user→client lookup.
3.  **Introduction**: Existing group member introduces a new user by sharing their client IDs.

Relay does not specify a user directory; this is application-specific.

### 7.3. Adding Users to Groups

To add a user (rather than a single client) to a group:

1.  Resolve the user to their set of client IDs.
2.  Fetch KeyPackages for each client.
3.  Add all clients to the group in a single Commit.
4.  Send a Welcome message to each client's welcome topic.

This ensures all of a user's devices join the group together.

**Multi-Device Consistency** [RFC 9750 Section 4]:

> "In applications where [the same set of clients] is the intended situation, other clients can check that a user is consistently represented by the same set of clients."

Applications MAY implement policies to detect if a user's client set changes unexpectedly.

### 7.4. Verifying User Identity

MLS provides `epoch_authenticator` for verifying that clients share the same group state. For user-level verification:

> *Recommendation* [RFC 9750 Section 8.4.3]: "Provide one or more out-of-band authentication mechanisms to limit the impact of an AS compromise."

**Safety Number Derivation**:

Applications can derive a stable "safety number" for out-of-band verification:

```
safety_number = MLS-Exporter(
    label: "relay user verification",
    context: sort(user_credential_hashes),
    length: 32
)
```

Display as a numeric code or QR code for users to compare.

## 8. Group Lifecycle

### 8.1. Creating a Group

1.  **Generate Group ID**: Create a random 16-byte value and hex-encode it (32 characters). This `group_id` is used both as the MLS `group_id` and in MQTT topic paths.

2.  **Initialize Group**: Create an MLS group with the `group_id` and chosen cipher suite. MUST support `MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519` (0x0001).

3.  **Fetch KeyPackages**: For each client to add, fetch from `relay/k/{client_id}`.

4.  **Add Members**: Generate Welcome messages and a Commit.

5.  **Distribute Welcomes**: Publish each Welcome to `relay/w/{client_id}`.

6.  **Publish GroupInfo**: Publish GroupInfo to `relay/g/{group_id}/i` (retained) with:
    *   `external_pub` extension (enables External Commits)
    *   `ratchet_tree` extension (provides tree for joiners)

7.  **Subscribe**: Subscribe to `relay/g/{group_id}/m`.

8.  **Send Commit**: Publish the Commit to `relay/g/{group_id}/m`.

### 8.2. Joining via Welcome

When a client receives a Welcome on `relay/w/{client_id}`:

1.  **Validate**: Verify the Welcome's KeyPackage matches one we published.
2.  **Check Replay**: Ensure this KeyPackage hasn't been used before.
3.  **Process**: Call MLS `Welcome` processing to derive group state.
4.  **Delete Init Key**: Delete the private `init_key` used.
5.  **Extract Group ID**: Get `group_id` from the MLS group state (it's the hex-encoded value set by the creator).
6.  **Subscribe**: Subscribe to `relay/g/{group_id}/m`.

### 8.3. Joining via External Commit

A client with access to GroupInfo can join without a Welcome:

1.  **Fetch GroupInfo**: Get from `relay/g/{group_id}/i`.
2.  **Validate**: Verify GroupInfo authenticity (signed by a member).
3.  **Create External Commit**: Generate an External Commit to add self.
4.  **Publish**: Send the Commit to `relay/g/{group_id}/m`.
5.  **Subscribe**: Subscribe to `relay/g/{group_id}/m`.

**Authentication**: To prove prior membership when rejoining, include a `PreSharedKey` proposal with `resumption_psk` from a previous epoch.

### 8.4. Sending Messages

1.  Encrypt application data using MLS `PrivateMessage` framing.
2.  Publish the `MLSMessage` to `relay/g/{group_id}/m`.

### 8.5. Receiving Messages

1.  Receive `MLSMessage` from subscribed topic.
2.  Process via MLS:
    *   `PrivateMessage`: Decrypt and deliver to application.
    *   `PublicMessage` (Commit): Apply to update group state.
    *   `PublicMessage` (Proposal): Buffer for future Commit.

### 8.6. Adding Members

1.  Fetch KeyPackages for clients to add.
2.  Generate Add proposals and Commit.
3.  Publish Welcomes to each new client's `relay/w/{client_id}`.
4.  Publish Commit to `relay/g/{group_id}/m`.
5.  Update retained GroupInfo on `relay/g/{group_id}/i`.

### 8.7. Removing Members

1.  Generate Remove proposal and Commit.
2.  Publish Commit to `relay/g/{group_id}/m`.
3.  Update retained GroupInfo on `relay/g/{group_id}/i`.

Removed clients will fail to decrypt subsequent messages and SHOULD unsubscribe.

### 8.8. Updating Keys

Periodic key updates provide forward secrecy and post-compromise security:

1.  Generate Update proposal and Commit.
2.  Publish Commit to `relay/g/{group_id}/m`.
3.  Update retained GroupInfo on `relay/g/{group_id}/i`.

> *Recommendation* [RFC 9750 Section 8.2.2]: "Mandate key updates from clients that are not otherwise sending messages."

**Policy**: Clients SHOULD update keys at least every 7 days or 1000 messages.

## 9. State Synchronization

### 9.1. Prevention

Use MQTT persistent sessions to receive messages during disconnection:

*   `Clean Start = 0`
*   `Session Expiry Interval = 604800` (7 days)

This allows clients to receive queued Commits and maintain state.

### 9.2. Detection

A client is desynchronized when:
*   MLS message processing fails with epoch/state errors.
*   The client was offline longer than the MQTT session expiry.

### 9.3. Recovery

Use MLS External Commits [RFC 9420 Section 12.4.3.2]:

1.  Fetch current GroupInfo from `relay/g/{group_id}/i`.
2.  Create an External Commit (resync flavor) to rejoin.
3.  Include `resumption_psk` proposal to prove prior membership.
4.  Publish External Commit to `relay/g/{group_id}/m`.

> *Recommendation* [RFC 9750 Section 5.3]: "Careful analysis of security implications should be made for any system for recovering from desynchronization."

**Security Note**: External Commits trust the GroupInfo. A malicious DS could provide stale GroupInfo. Applications concerned about this SHOULD verify GroupInfo freshness via out-of-band means.

## 10. Operational Considerations

### 10.1. Transport Security

> *Recommendation* [RFC 9750 Section 8.1]: "Use transports that provide reliability and metadata confidentiality whenever possible, e.g., by transmitting MLS messages over a protocol such as TLS or QUIC."

MQTT connections SHOULD use TLS 1.3 or later. This protects:
*   Client credentials during connection.
*   Topic patterns from network observers.
*   Message metadata in transit.

MLS provides end-to-end encryption; TLS provides transport encryption. Both are recommended.

### 10.2. Message Ordering

MQTT QoS 1 provides at-least-once delivery but not strict ordering.

**Epoch Ordering**: Process messages in epoch order. Buffer messages for future epochs until the transitioning Commit arrives.

**Generation Ordering**: Within an epoch, `PrivateMessage` includes a per-sender `generation` counter. Buffer briefly (RECOMMENDED: 30 seconds) to allow reordering.

**Duplicate Detection**: Track `(epoch, sender_leaf_index, generation)` and discard duplicates.

**Commit Ordering** [RFC 9750 Section 5.2]: When multiple Commits arrive for the same epoch, accept the first valid one and discard others. The MQTT broker provides ordering; clients process in order received.

### 10.3. Access Control

MLS allows any member to send any proposal. Applications MAY enforce additional policies:

> *Recommendation* [RFC 9750 Section 6.4]: "Avoid using inconsistent access control policies, especially when using encrypted group operations."

Policies must be consistent across all clients to prevent state divergence.

> *Recommendation* [RFC 9750 Section 6.4]: "Have an explicit group policy setting the conditions under which external joins are allowed."

If GroupInfo is published, anyone with access can attempt an External Commit. Applications SHOULD implement access control at the broker level or validate External Commits against policy.

### 10.4. Credential Management

> *Recommendation* [RFC 9750 Section 6.5]: "Have a uniform credential validation process to ensure that all group members evaluate other members' credentials in the same way."

> *Recommendation* [RFC 9750 Section 6.5]: "Proactively rotate credentials, especially if a credential is about to become invalid."

Clients SHOULD update their KeyPackages before credential expiry.

### 10.5. Idle Client Eviction

> *Recommendation* [RFC 9750 Section 8.2.2]: "Evict clients that are idle for too long."

Clients that don't send messages or key updates weaken forward secrecy. Applications SHOULD define a maximum idle period (e.g., 30 days) after which idle members are removed.

## 11. Security Considerations

### 11.1. Trust Model

Following [RFC 9750] Section 4:

*   **Delivery Service (MQTT Broker)**: Untrusted for confidentiality and integrity. Trusted only for availability and ordering.
*   **Authentication Service**: Application-provided. Compromise allows impersonation.

MLS guarantees that a compromised DS cannot:
*   Read message contents.
*   Forge messages from members.
*   Undetectably add members to groups.

A compromised DS CAN:
*   Observe metadata (who communicates, when, message sizes).
*   Block or delay messages (DoS).
*   Provide stale KeyPackages (limited attack on PCS).

### 11.2. Metadata Privacy

**Visible to Broker**:
*   Client IDs (from topic subscriptions)
*   Group IDs (from topic subscriptions)
*   Message timing and sizes
*   Group membership (who subscribes to which group)

**Hidden from Broker**:
*   Message contents (MLS encryption)
*   Sender identity within group (MLS `PrivateMessage` hides sender from non-members)

**Comparison**:

| System | Server Sees Social Graph | Content Encrypted |
| :--- | :--- | :--- |
| Relay | Yes | Yes (MLS) |
| Signal | Yes (without Sealed Sender) | Yes |
| Matrix | Yes | Yes (Megolm) |

### 11.3. DoS Considerations

Following [RFC 9750] Section 8.1.3:

> "In general, we do not consider DoS resistance to be the responsibility of the protocol."

DoS protection is handled at the transport and infrastructure layers, not by Relay:

*   **Transport Security**: TLS/QUIC prevents network attackers from selectively targeting MLS traffic.
*   **Broker Authentication**: MQTT broker requires client authentication, preventing anonymous abuse.
*   **Broker Rate Limiting**: MQTT brokers can enforce per-client rate limits and quotas.

> *Recommendation* [RFC 9750]: "Use credentials uncorrelated with specific users to help prevent DoS attacks, in a privacy-preserving manner."

**Residual Risks** (for authenticated attackers):

*   **KeyPackage Exhaustion**: Authenticated attacker consumes all KeyPackages.
*   **Message Flooding**: Malicious group member floods the group.

These are addressed by broker-level policies (rate limits, quotas) and group-level policies (member removal).

## 12. IANA Considerations

This document has no IANA actions.

## 13. References

*   [RFC 9420] The Messaging Layer Security (MLS) Protocol, https://www.rfc-editor.org/rfc/rfc9420
*   [RFC 9750] The Messaging Layer Security (MLS) Architecture, https://www.rfc-editor.org/rfc/rfc9750
*   [RFC 2119] Key words for use in RFCs to Indicate Requirement Levels, https://www.rfc-editor.org/rfc/rfc2119
*   [RFC 8174] Ambiguity of Uppercase vs Lowercase in RFC 2119 Key Words, https://www.rfc-editor.org/rfc/rfc8174
*   [MQTT-5.0] OASIS MQTT Version 5.0, https://docs.oasis-open.org/mqtt/mqtt/v5.0/mqtt-v5.0.html

## Appendix A. Design Rationale

### A.1. Client-Centric Design

Relay follows MLS's client model rather than introducing a user abstraction at the protocol level because:

1.  **MLS Alignment**: MLS operates on clients, not users [RFC 9750 Section 3.7].
2.  **Flexibility**: Different applications have different user models (single-device, multi-device, shared-device).
3.  **Simplicity**: User management adds complexity that not all deployments need.

Applications requiring user-level operations can implement them per Section 7.

### A.2. Native MLS Framing

Relay uses `MLSMessage` directly rather than custom wrappers because:

1.  **Interoperability**: Standard MLS libraries can process messages without Relay-specific code.
2.  **Simplicity**: No additional serialization layer to implement or debug.
3.  **Future-Proofing**: New MLS message types work automatically.

### A.3. Minimal Topic Structure

The topic structure uses short prefixes (`/k/`, `/w/`, `/g/`) to minimize MQTT overhead. Topics are:

*   `/k/{client_id}` - KeyPackages (retained)
*   `/w/{client_id}` - Welcome messages
*   `/g/{group_id}/m` - Group messages
*   `/g/{group_id}/i` - Group GroupInfo (retained)

### A.4. GroupInfo Publication

Publishing GroupInfo enables External Commits for:
*   State recovery without peer cooperation.
*   Joining public/open groups.

The tradeoff is metadata exposure (GroupInfo reveals group structure). Applications can restrict access via broker ACLs.

### A.5. Deferred Features

The following features are deferred to future versions:

| Feature | Rationale |
| :--- | :--- |
| Sealed Sender | Adds complexity; unclear if metadata hiding from broker is required |
| User Directory | Application-specific; many valid approaches |
| Message Acknowledgments | Can be built on MLS-Exporter at application layer |

### A.6. Alignment with RFC 9750

This specification incorporates recommendations from [RFC 9750]:

| Recommendation | Section | Implementation |
| :--- | :--- | :--- |
| Use TLS/QUIC transport | 8.1 | Section 10.1 |
| Last resort KeyPackage handling | 5.1 | Section 6.4 |
| Delete init_key after Welcome | 5.1 | Section 8.2 |
| Consistent access control | 6.4 | Section 10.3 |
| Uniform credential validation | 6.5 | Section 10.4 |
| Evict idle clients | 8.2.2 | Section 10.5 |
| Out-of-band authentication | 8.4.3 | Section 7.4 |
| Prefer strong credential types | 8.4.2 | Section 6.2 |
