import SwiftUI

struct ConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = ConversationController()
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 34))
                    .foregroundStyle(symbolTint)
                    .symbolEffect(
                        .pulse,
                        isActive: controller.isReconnecting
                            || controller.state == .connecting
                            || controller.state == .recording
                            || controller.state == .playing
                    )

                Text(controller.state.displayTitle(reconnecting: controller.isReconnecting))
                    .font(.headline)

                Text(controller.state.displayDetail(reconnecting: controller.isReconnecting))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)

                if let line = controller.transcripts.last(where: {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    Text(line.text)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .accessibilityIdentifier("latestTranscript")
                }

                if let actionTitle = controller.state.primaryActionTitle {
                    Button(actionTitle) {
                        Task { await controller.performPrimaryAction() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.state.tint)
                    .disabled(controller.actionInFlight || controller.isReconnecting)
                    .accessibilityIdentifier("primaryAction")
                } else if controller.actionInFlight || controller.state == .connecting {
                    ProgressView()
                }

                if (controller.state.showsReplayAction && controller.hasLastResponse)
                    || controller.state.showsEndAction {
                    HStack(spacing: 8) {
                        if controller.state.showsReplayAction && controller.hasLastResponse {
                            Button("Replay") {
                                Task { await controller.replay() }
                            }
                            .disabled(controller.actionInFlight || controller.isReconnecting)
                            .accessibilityIdentifier("replayAction")
                        }
                        if controller.state.showsEndAction {
                            Button("End") {
                                Task { await controller.endSession() }
                            }
                            .disabled(controller.actionInFlight || controller.isReconnecting)
                            .accessibilityIdentifier("endAction")
                        }
                    }
                    .font(.caption2)
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
                // Simulator/debug launch arguments. See docs/debugging.md.
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
            .sensoryFeedback(trigger: controller.hapticSignal) { _, signal in
                switch signal?.kind {
                case .start:
                    .start
                case .stop:
                    .stop
                case .success:
                    .success
                case .failure:
                    .error
                case .click:
                    .selection
                case nil:
                    nil
                }
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

    private var symbolName: String {
        if controller.isReconnecting {
            return ConversationState.connecting.symbolName
        }
        return controller.state.symbolName
    }

    private var symbolTint: Color {
        if controller.isReconnecting {
            return ConversationState.connecting.tint
        }
        return controller.state.tint
    }
}

#Preview {
    ConversationView()
}
