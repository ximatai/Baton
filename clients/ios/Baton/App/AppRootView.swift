import SwiftUI

struct ContentView: View {
    @StateObject private var model = BatonViewModel()
    @State private var isEndConfirmationPresented = false
    @State private var isShowingScanner = false
    @State private var isShowingAbout = false
    @State private var navigationPath: [String] = []
    @State private var opensPairedConversation = false

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
            .navigationDestination(for: String.self) { _ in
                ConversationView(model: model)
                    .navigationTitle(model.activeConversationTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
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
        .sheet(isPresented: $isShowingScanner) {
            QRScannerSheet { pairingURL in
                opensPairedConversation = true
                model.connect(pairingURL: pairingURL)
            }
        }
        .sheet(isPresented: pairingBinding) {
            NavigationStack {
                PairingWaitView(model: model)
                    .padding(20)
                    .navigationTitle("加入新会话")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
        .onChange(of: model.activeSessionID) { _, sessionID in
            if opensPairedConversation, let sessionID {
                navigationPath = [sessionID]
                opensPairedConversation = false
            } else if sessionID == nil {
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

    private var pairingBinding: Binding<Bool> {
        Binding(
            get: { model.isWaitingForApproval },
            set: { isPresented in
                if !isPresented, model.isWaitingForApproval {
                    model.cancelPendingPairing()
                }
            }
        )
    }

    private func beginScanning() {
        isShowingScanner = true
    }

    private func openSession(_ sessionID: String) {
        model.activateSavedSession(id: sessionID)
        navigationPath = [sessionID]
    }
}

#Preview { ContentView() }
