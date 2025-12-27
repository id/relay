import Foundation
import SwiftData

@Model
final class BrokerConfig {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var useTLS: Bool
    var username: String?
    var password: String?
    var isDefault: Bool

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        useTLS: Bool,
        username: String? = nil,
        password: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.password = password
        self.isDefault = isDefault
    }

    static var defaultConfig: BrokerConfig {
        BrokerConfig(
            name: "EMQX Public",
            host: "broker.emqx.io",
            port: 8883,
            useTLS: true,
            isDefault: true
        )
    }
}
