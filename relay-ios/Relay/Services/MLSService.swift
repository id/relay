import Foundation
import SwiftOpenMLS

/// Service managing MLS encryption and group operations using the Relay protocol.
/// Uses RelayMlsClient which properly persists the signer for the client's lifetime.
@Observable
final class MLSService: @unchecked Sendable {
    // MARK: - Public Properties

    private(set) var isInitialized = false

    /// The client ID used for MLS operations
    var clientId: String {
        client?.clientId() ?? storedClientId
    }

    // MARK: - Private Properties

    /// The underlying MLS client (persists signer and manages groups)
    private var client: RelayMlsClient?
    private let storedClientId: String

    // MARK: - Initialization

    init(clientId: String) {
        self.storedClientId = clientId
    }

    // MARK: - Client Setup

    /// Initialize the MLS client
    func initialize() throws {
        guard !isInitialized else { return }

        do {
            // Create the RelayMlsClient - this generates and persists the signer
            client = try RelayMlsClient(clientId: storedClientId)
            isInitialized = true
        } catch {
            throw MLSServiceError.initializationFailed(
                error.localizedDescription
            )
        }
    }

    /// Create a KeyPackage for this client (CBOR-wrapped MLSMessage format per Relay protocol)
    /// This should be published to relay/k/{clientId} as a retained message
    func createKeyPackage() throws -> Data {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        do {
            let keyPackageBytes = try client.createKeyPackage()
            return Data(keyPackageBytes)
        } catch {
            throw MLSServiceError.keyPackageCreationFailed(
                error.localizedDescription
            )
        }
    }

    // MARK: - Group Management

    /// Create a new MLS group with a random 16-byte group ID
    /// - Returns: The hex-encoded group ID
    func createGroup() throws -> String {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        do {
            return try client.createGroup()
        } catch {
            throw MLSServiceError.groupCreationFailed(
                error.localizedDescription
            )
        }
    }

    /// Add a member to a group using their KeyPackage (CBOR-wrapped format)
    /// - Parameters:
    ///   - groupId: The hex-encoded group ID
    ///   - keyPackageBytes: The CBOR-wrapped KeyPackage from relay/k/{contactId}
    /// - Returns: Result containing Welcome bytes (send to relay/w/{contactId}) and Commit bytes
    func addMember(to groupId: String, keyPackageData: Data) throws
        -> AddMemberResult
    {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        do {
            return try client.addMember(
                groupId: groupId,
                keyPackageBytes: [UInt8](keyPackageData)
            )
        } catch {
            throw MLSServiceError.addMemberFailed(error.localizedDescription)
        }
    }

    /// Join a group from a Welcome message received on relay/w/{clientId}
    /// - Parameter welcomeData: The Welcome message bytes
    /// - Returns: Result containing the group ID to subscribe to
    func joinFromWelcome(welcomeData: Data) throws -> JoinGroupResult {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        do {
            return try client.joinFromWelcome(
                welcomeBytes: [UInt8](welcomeData)
            )
        } catch {
            throw MLSServiceError.joinGroupFailed(error.localizedDescription)
        }
    }

    /// Check if we have a group with the given ID
    func hasGroup(groupId: String) -> Bool {
        guard let client = client else { return false }
        do {
            _ = try client.members(groupId: groupId)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Encryption/Decryption

    /// Encrypt a message for a group
    /// - Parameters:
    ///   - message: The plaintext message
    ///   - groupId: The hex-encoded group ID
    /// - Returns: Encrypted message bytes (MLS ciphertext)
    func encrypt(message: String, for groupId: String) throws -> Data {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        guard let messageData = message.data(using: .utf8) else {
            throw MLSServiceError.encodingError
        }

        do {
            let ciphertext = try client.encrypt(
                groupId: groupId,
                plaintext: [UInt8](messageData)
            )
            return Data(ciphertext)
        } catch {
            throw MLSServiceError.encryptionFailed(error.localizedDescription)
        }
    }

    /// Decrypt a message from a group
    /// - Parameters:
    ///   - ciphertext: The encrypted message bytes
    ///   - groupId: The hex-encoded group ID
    /// - Returns: Decrypted plaintext message
    func decrypt(ciphertext: Data, for groupId: String) throws -> String {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        do {
            let decrypted = try client.decrypt(
                groupId: groupId,
                ciphertext: [UInt8](ciphertext)
            )

            guard
                let message = String(
                    data: Data(decrypted.plaintext),
                    encoding: .utf8
                )
            else {
                throw MLSServiceError.decodingError
            }

            return message
        } catch {
            throw MLSServiceError.decryptionFailed(error.localizedDescription)
        }
    }

    // MARK: - Group Info

    /// Get the list of member client IDs in a group
    func getMembers(for groupId: String) throws -> [String] {
        guard let client = client else {
            throw MLSServiceError.notInitialized
        }

        do {
            return try client.members(groupId: groupId)
        } catch {
            throw MLSServiceError.groupNotFound(groupId)
        }
    }
}

// MARK: - Errors

enum MLSServiceError: LocalizedError {
    case notInitialized
    case initializationFailed(String)
    case keyPackageCreationFailed(String)
    case groupCreationFailed(String)
    case joinGroupFailed(String)
    case groupNotFound(String)
    case addMemberFailed(String)
    case encryptionFailed(String)
    case decryptionFailed(String)
    case encodingError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "MLS service not initialized"
        case .initializationFailed(let details):
            return "Failed to initialize MLS: \(details)"
        case .keyPackageCreationFailed(let details):
            return "Failed to create key package: \(details)"
        case .groupCreationFailed(let details):
            return "Failed to create group: \(details)"
        case .joinGroupFailed(let details):
            return "Failed to join group: \(details)"
        case .groupNotFound(let groupId):
            return "Group not found: \(groupId)"
        case .addMemberFailed(let details):
            return "Failed to add member: \(details)"
        case .encryptionFailed(let details):
            return "Failed to encrypt message: \(details)"
        case .decryptionFailed(let details):
            return "Failed to decrypt message: \(details)"
        case .encodingError:
            return "Failed to encode message"
        case .decodingError:
            return "Failed to decode message"
        }
    }
}
