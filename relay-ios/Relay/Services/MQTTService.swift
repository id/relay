import Combine
import Foundation
import MQTT

/// Connection state for the MQTT service
enum MQTTConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// Service managing MQTT connections and pub/sub
@Observable
final class MQTTService: @unchecked Sendable {
    // MARK: - Public Properties

    private(set) var connectionState: MQTTConnectionState = .disconnected
    private(set) var clientId: String

    /// Publisher for received messages
    let receivedMessages = PassthroughSubject<
        (topic: String, payload: Data), Never
    >()

    // MARK: - Private Properties

    private var client: MQTTClient.V5?
    private var subscribedTopics: Set<String> = []
    private var currentConfig: BrokerConfig?
    private var delegateHandler: MQTTDelegateHandler?

    // MARK: - Initialization

    init() {
        // Generate a unique client ID
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(16)
        self.clientId = "relay-ios-\(suffix)"
    }

    // MARK: - Connection Management

    /// Connect to an MQTT broker
    func connect(config: BrokerConfig) async throws {
        guard connectionState != .connecting && connectionState != .connected
        else {
            return
        }

        await MainActor.run {
            connectionState = .connecting
        }

        currentConfig = config

        // Create endpoint
        let endpoint: Endpoint
        if config.useTLS {
            endpoint = .tls(host: config.host, port: UInt16(config.port))
        } else {
            endpoint = .tcp(host: config.host, port: UInt16(config.port))
        }

        // Create MQTT V5 client
        let client = MQTTClient.V5(endpoint)
        client.config.keepAlive = 60
        client.config.connectTimeout = 10

        // Set up delegate handler
        let handler = MQTTDelegateHandler(service: self)
        client.delegate = handler
        self.delegateHandler = handler

        self.client = client

        // Create identity
        var identity = Identity(clientId)
        if let username = config.username, !username.isEmpty {
            identity = Identity(
                clientId,
                username: username,
                password: config.password
            )
        }

        // Connect
        do {
            let _ = try await client.open(identity).wait()
            await MainActor.run {
                connectionState = .connected
            }
        } catch {
            await MainActor.run {
                connectionState = .error(error.localizedDescription)
            }
            throw error
        }
    }

    /// Disconnect from the broker
    func disconnect() {
        let _ = client?.close()
        connectionState = .disconnected
        subscribedTopics.removeAll()
    }

    // MARK: - Pub/Sub

    /// Subscribe to a topic
    func subscribe(to topic: String, qos: MQTTQoS = .atLeastOnce) async throws {
        guard let client = client, connectionState == .connected else {
            throw MQTTServiceError.notConnected
        }

        let _ = try await client.subscribe(to: topic, qos: qos).wait()
        subscribedTopics.insert(topic)
    }

    /// Unsubscribe from a topic
    func unsubscribe(from topic: String) async throws {
        guard let client = client, connectionState == .connected else {
            throw MQTTServiceError.notConnected
        }

        let _ = try await client.unsubscribe(from: topic).wait()
        subscribedTopics.remove(topic)
    }

    /// Publish a message to a topic
    func publish(
        to topic: String,
        payload: Data,
        qos: MQTTQoS = .atLeastOnce,
        retain: Bool = false
    ) async throws {
        guard let client = client, connectionState == .connected else {
            throw MQTTServiceError.notConnected
        }

        let _ = try await client.publish(
            to: topic,
            payload: payload,
            qos: qos,
            retain: retain
        ).wait()
    }

    /// Publish a string message to a topic
    func publish(
        to topic: String,
        message: String,
        qos: MQTTQoS = .atLeastOnce,
        retain: Bool = false
    ) async throws {
        guard let data = message.data(using: .utf8) else {
            throw MQTTServiceError.encodingError
        }
        try await publish(to: topic, payload: data, qos: qos, retain: retain)
    }

    // MARK: - Internal Callbacks

    fileprivate func handleStatusUpdate(_ status: Status) {
        DispatchQueue.main.async { [weak self] in
            switch status {
            case .opened:
                self?.connectionState = .connected
            case .opening:
                self?.connectionState = .connecting
            case .closed:
                self?.connectionState = .disconnected
            case .closing:
                break
            }
        }
    }

    fileprivate func handleMessage(topic: String, payload: Data) {
        DispatchQueue.main.async { [weak self] in
            print(
                "[MQTT] Received message on topic: \(topic) (\(payload.count) bytes)"
            )
            self?.receivedMessages.send((topic: topic, payload: payload))
            self?.messageHandler?(topic, payload)
        }
    }

    // MARK: - Message Handler

    private var messageHandler: ((String, Data) -> Void)?

    /// Set a callback for incoming messages
    func setMessageHandler(_ handler: @escaping (String, Data) -> Void) {
        messageHandler = handler
    }

    fileprivate func handleError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.connectionState = .error(error.localizedDescription)
        }
    }
}

// MARK: - Delegate Handler

/// Separate delegate class to handle MQTT callbacks
private final class MQTTDelegateHandler: MQTTDelegate, @unchecked Sendable {
    weak var service: MQTTService?

    init(service: MQTTService) {
        self.service = service
    }

    func mqtt(_ mqtt: MQTTClient, didUpdate status: Status, prev: Status) {
        service?.handleStatusUpdate(status)
    }

    func mqtt(_ mqtt: MQTTClient, didReceive message: MQTT.Message) {
        service?.handleMessage(topic: message.topic, payload: message.payload)
    }

    func mqtt(_ mqtt: MQTTClient, didReceive error: Error) {
        service?.handleError(error)
    }
}

// MARK: - Errors

enum MQTTServiceError: LocalizedError {
    case invalidURL
    case notConnected
    case encodingError
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid broker URL"
        case .notConnected:
            return "Not connected to broker"
        case .encodingError:
            return "Failed to encode message"
        case .timeout:
            return "Connection timed out"
        }
    }
}
