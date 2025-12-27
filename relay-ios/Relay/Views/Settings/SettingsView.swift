import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var brokerConfigs: [BrokerConfig]

    @AppStorage("appMode") private var appMode = "relay"
    @Bindable var mqttService: MQTTService

    @State private var showingEditBroker = false
    @State private var editingBroker: BrokerConfig?

    private var currentBroker: BrokerConfig? {
        brokerConfigs.first { $0.isDefault } ?? brokerConfigs.first
    }

    var body: some View {
        NavigationStack {
            List {
                // Connection Section
                Section("Connection") {
                    if let broker = currentBroker {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(broker.name)
                                .font(.headline)
                            Text("\(broker.host):\(broker.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .onTapGesture {
                            editingBroker = broker
                            showingEditBroker = true
                        }
                    } else {
                        Button("Add Broker") {
                            let newBroker = BrokerConfig.defaultConfig
                            modelContext.insert(newBroker)
                            editingBroker = newBroker
                            showingEditBroker = true
                        }
                    }

                    HStack {
                        Text("Status")
                        Spacer()
                        ConnectionStatusView(state: mqttService.connectionState)
                    }

                    if mqttService.connectionState == .disconnected {
                        Button("Connect") {
                            Task {
                                if let broker = currentBroker {
                                    try? await mqttService.connect(
                                        config: broker
                                    )
                                }
                            }
                        }
                    } else if mqttService.connectionState == .connected {
                        Button("Disconnect", role: .destructive) {
                            mqttService.disconnect()
                        }
                    }
                }

                // App Mode Section
                Section("App Mode") {
                    Picker("Mode", selection: $appMode) {
                        Label("Relay (Encrypted)", systemImage: "lock.fill")
                            .tag("relay")
                        Label("Raw MQTT", systemImage: "network")
                            .tag("mqtt")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                // Client Info Section
                Section("Client Info") {
                    HStack {
                        Text("Client ID")
                        Spacer()
                        Text(mqttService.clientId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // About Section
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("0.1.0")
                            .foregroundStyle(.secondary)
                    }

                    Link(
                        destination: URL(
                            string: "https://github.com/id/relay"
                        )!
                    ) {
                        HStack {
                            Text("Source Code")
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingEditBroker) {
                if let broker = editingBroker {
                    EditBrokerView(broker: broker)
                }
            }
        }
    }
}

struct EditBrokerView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var broker: BrokerConfig

    var body: some View {
        NavigationStack {
            Form {
                Section("Broker Details") {
                    TextField("Name", text: $broker.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Host", text: $broker.host)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", value: $broker.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    Toggle("Use TLS", isOn: $broker.useTLS)
                }

                Section("Authentication (Optional)") {
                    TextField(
                        "Username",
                        text: Binding(
                            get: { broker.username ?? "" },
                            set: { broker.username = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    SecureField(
                        "Password",
                        text: Binding(
                            get: { broker.password ?? "" },
                            set: { broker.password = $0.isEmpty ? nil : $0 }
                        )
                    )
                }
            }
            .navigationTitle("Edit Broker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView(mqttService: MQTTService())
        .modelContainer(for: BrokerConfig.self, inMemory: true)
}
