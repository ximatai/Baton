import SwiftUI

private struct ConversationRoute: Hashable {
    let sessionID: String
    let title: String
}

struct ContentView: View {
    @StateObject private var model = BatonViewModel()
    @State private var isEndConfirmationPresented = false
    @State private var isShowingScanner = false
    @State private var isShowingAbout = false
    @State private var navigationPath: [ConversationRoute] = []
    @State private var opensPairedConversation = false
    @State private var pendingPairedSessionID: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ConnectView(
                model: model,
                scan: beginScanning,
                openSession: openSession
            )
            .navigationTitle("Baton")
            .toolbar {
                if navigationPath.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { isShowingAbout = true } label: {
                            Image(systemName: "lightbulb")
                        }
                        .accessibilityLabel("关于 Baton")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: beginScanning) {
                            Image(systemName: "qrcode.viewfinder")
                        }
                        .accessibilityLabel("扫码加入新会话")
                    }
                }
            }
            .navigationDestination(for: ConversationRoute.self) { route in
                ConversationView(model: model)
                    // Keep the title in the route for immediate QR-driven navigation.
                    .navigationTitle(route.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // Keep the title visible on the first QR-driven push.
                        ToolbarItem(placement: .principal) {
                            Text(route.title)
                                .lineLimit(1)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("重新连接", systemImage: "arrow.clockwise") { model.reconnect() }
                                if model.canEndActiveConversation {
                                    Button("结束对话", systemImage: "xmark.circle", role: .destructive) { isEndConfirmationPresented = true }
                                }
                                Button("断开本次会话", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.disconnect() }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
            }
        }
        .confirmationDialog("结束当前对话？", isPresented: $isEndConfirmationPresented, titleVisibility: .visible) {
            Button("结束对话", role: .destructive) { model.endConversation() }
        } message: {
            Text("所有已加入这段对话的设备都会退出。")
        }
        .sheet(isPresented: $isShowingAbout) {
            BatonAboutSheet()
        }
        .sheet(isPresented: $isShowingScanner, onDismiss: openPairedConversationAfterSheetDismissal) {
            PairingFlowSheet(model: model) { pairingURL in
                opensPairedConversation = true
                model.connect(pairingURL: pairingURL)
            }
        }
        .onChange(of: model.completedPairingSessionID) { _, sessionID in
            if opensPairedConversation, let sessionID {
                // Pairing is an action, while a conversation key is stable.
                // The explicit completion event therefore also covers scanning
                // back into the currently active conversation.
                pendingPairedSessionID = sessionID
                opensPairedConversation = false
                isShowingScanner = false
            }
        }
        .onChange(of: model.activeSessionID) { _, sessionID in
            if sessionID == nil {
                navigationPath = []
            }
        }
        .onChange(of: navigationPath) { _, path in
            if path.isEmpty {
                model.suspendActiveConversation()
            }
        }
        .task { model.restoreSavedSessionIfPossible() }
    }

    private func beginScanning() {
        isShowingScanner = true
    }

    private func openSession(_ sessionID: String) {
        model.activateSavedSession(id: sessionID)
        navigationPath = [conversationRoute(sessionID: sessionID)]
    }

    private func conversationRoute(sessionID: String) -> ConversationRoute {
        ConversationRoute(sessionID: sessionID, title: model.activeConversationTitle)
    }

    private func openPairedConversationAfterSheetDismissal() {
        guard let sessionID = pendingPairedSessionID else { return }
        pendingPairedSessionID = nil
        navigationPath = [conversationRoute(sessionID: sessionID)]
    }
}

/// Keeps scanning and the subsequent approval wait in one modal presentation.
/// The only sheet dismissal happens after pairing resolution or explicit cancel.
private struct PairingFlowSheet: View {
    @ObservedObject var model: BatonViewModel
    let connect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasScanned = false

    var body: some View {
        NavigationStack {
            Group {
                if hasScanned {
                    if let error = pairingFailure {
                        VStack(alignment: .leading, spacing: 18) {
                            Label("无法加入对话", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("重试", action: model.retryLastConnection)
                                    .buttonStyle(.borderedProminent)
                                Button("重新扫描", action: restartScanning)
                                    .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    } else {
                        PairingWaitView(model: model, cancel: cancel)
                            .padding(20)
                    }
                } else {
                    QRScannerSheet { pairingURL in
                        hasScanned = true
                        connect(pairingURL)
                    }
                }
            }
            .navigationTitle(hasScanned ? "加入新会话" : "扫描二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(hasScanned ? "取消" : "返回") { cancel() }
                }
            }
        }
        .presentationDetents(hasScanned ? [.medium] : [.large])
        .interactiveDismissDisabled(hasScanned)
    }

    private func cancel() {
        if hasScanned { model.cancelPendingPairing() }
        dismiss()
    }

    private var pairingFailure: String? {
        guard hasScanned, !model.isBusy, !model.isWaitingForApproval else { return nil }
        return model.errorMessage
    }

    private func restartScanning() {
        model.cancelPendingPairing()
        hasScanned = false
    }
}

#Preview { ContentView() }
