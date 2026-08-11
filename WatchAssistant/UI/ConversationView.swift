import SwiftUI

struct ConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = ConversationController()
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: controller.state.symbolName)
                .font(.system(size: 34))
                .foregroundStyle(controller.state.tint)
                .symbolEffect(.pulse, isActive: controller.state == .connecting)

            Text(controller.state.title)
                .font(.headline)

            Text(controller.state.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            if let actionTitle = controller.state.primaryActionTitle {
                Button(actionTitle) {
                    Task { await controller.performPrimaryAction() }
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.state.tint)
                .disabled(controller.actionInFlight || controller.state == .ready)
            } else if controller.actionInFlight {
                ProgressView()
            }

            if controller.state == .ready {
                Text("Voice capture starts in phase two")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $showsSettings) {
            CredentialSettingsView(controller: controller)
        }
        .task {
            await controller.connectIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                if phase == .active {
                    await controller.connectIfNeeded()
                } else {
                    await controller.disconnect()
                }
            }
        }
    }
}

#Preview {
    ConversationView()
}
