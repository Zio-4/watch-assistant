import SwiftUI

struct ConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = ConversationController()
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Image(systemName: controller.state.symbolName)
                    .font(.system(size: 34))
                    .foregroundStyle(controller.state.tint)
                    .symbolEffect(
                        .pulse,
                        isActive: controller.state == .connecting || controller.state == .recording
                    )

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
                    .disabled(controller.actionInFlight)
                    .accessibilityIdentifier("primaryAction")
                } else if controller.actionInFlight {
                    ProgressView()
                }

                Button("Settings") {
                    showsSettings = true
                }
                .font(.caption)
            }
            .padding(.horizontal, 8)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-preview-ready") {
                    controller.preparePreviewReady()
                    if ProcessInfo.processInfo.arguments.contains("-auto-talk") {
                        Task {
                            try? await Task.sleep(for: .milliseconds(800))
                            await controller.performPrimaryAction()
                            try? await Task.sleep(for: .seconds(2))
                            await controller.performPrimaryAction()
                        }
                    }
                    return
                }
                #endif
                await controller.connectIfNeeded()
            }
            .onChange(of: scenePhase) { _, phase in
                Task {
                    switch phase {
                    case .active:
                        await controller.connectIfNeeded()
                    case .background:
                        await controller.disconnect()
                    default:
                        // Sheets make the scene inactive on watchOS. Do not
                        // tear down a connection the user just asked to start.
                        break
                    }
                }
            }
        }
    }
}

#Preview {
    ConversationView()
}
