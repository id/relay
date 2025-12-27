import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding =
        false
    @AppStorage("appMode") private var appMode = "relay"

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Header
            VStack(spacing: 12) {
                Image(systemName: "message.badge.filled.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text("Welcome to Relay")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Choose how you want to use the app")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Mode selection cards
            VStack(spacing: 16) {
                ModeCard(
                    icon: "lock.fill",
                    title: "Relay Mode",
                    description:
                        "End-to-end encrypted messaging using MLS protocol",
                    isSelected: appMode == "relay",
                    accentColor: .blue
                ) {
                    appMode = "relay"
                }

                ModeCard(
                    icon: "network",
                    title: "Raw MQTT",
                    description: "Generic MQTT client for pub/sub to any topic",
                    isSelected: appMode == "mqtt",
                    accentColor: .orange
                ) {
                    appMode = "mqtt"
                }
            }
            .padding(.horizontal)

            Spacer()

            // Continue button
            Button {
                hasCompletedOnboarding = true
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }
}

struct ModeCard: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(accentColor)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(
                    systemName: isSelected ? "checkmark.circle.fill" : "circle"
                )
                .font(.title2)
                .foregroundStyle(isSelected ? accentColor : .secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        isSelected
                            ? accentColor.opacity(0.1)
                            : Color.gray.opacity(0.15)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingView()
}
