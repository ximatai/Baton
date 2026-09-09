import SwiftUI

private struct ConversationRoute: Hashable {
    let sessionID: String
    let title: String
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = BatonViewModel()
    @State private var isEndConfirmationPresented = false
    @State private var isShowingScanner = false
    @State private var isShowingAbout = false
    @State private var navigationPath: [ConversationRoute] = []
    @StateObject private var pairingPresentation = PairingPresentationCoordinator()
    @State private var releaseNoteToPresent: ReleaseNote?
    @State private var lastPresentedReleaseNote: ReleaseNote?
    private let releaseNotesManager = ReleaseNotesManager.shared

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
        .sheet(isPresented: $isShowingAbout, onDismiss: presentReleaseNoteIfSafe) {
            BatonAboutSheet()
        }
        .sheet(item: $releaseNoteToPresent, onDismiss: markPresentedReleaseNoteRead) { note in
            ReleaseNoteView(note: note) {
                releaseNoteToPresent = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $isShowingScanner, onDismiss: openPairedConversationAfterSheetDismissal) {
            PairingFlowSheet(
                model: model,
                completedSessionID: pairingPresentation.completedSessionID,
                connect: { pairingURL in
                    pairingPresentation.beginPairingFlow()
                    model.connect(pairingURL: pairingURL)
                },
                cancelled: pairingPresentation.discardPairingFlow
            )
        }
        .onChange(of: model.completedPairingSessionID) { _, sessionID in
            if let sessionID {
                let accepted = pairingPresentation.acceptCompletedPairing(
                    sessionID: sessionID,
                    isSheetPresented: isShowingScanner,
                    sceneIsActive: scenePhase == .active,
                    sceneIsBackground: scenePhase == .background
                )
                if !accepted, scenePhase == .background {
                    isShowingScanner = false
                }
            }
        }
        .onChange(of: pairingPresentation.navigationSessionID) { _, sessionID in
            if sessionID != nil { isShowingScanner = false }
        }
        .onChange(of: model.activeSessionID) { _, sessionID in
            if sessionID == nil {
                navigationPath = []
                if pairingPresentation.isPresentingCompletion {
                    pairingPresentation.discardPairingFlow()
                    isShowingScanner = false
                }
            }
        }
        .onChange(of: navigationPath) { _, path in
            if path.isEmpty {
                model.suspendActiveConversation()
                presentReleaseNoteIfSafe()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if pairingPresentation.sceneActivityChanged(
                isActive: phase == .active,
                isBackground: phase == .background
            ) {
                isShowingScanner = false
            }
            if phase == .background {
                model.suspendActiveConversation()
            }
            if phase == .active {
                presentReleaseNoteIfSafe()
            }
        }
        .onChange(of: model.isBusy) { _, busy in
            if !busy { presentReleaseNoteIfSafe() }
        }
        .onChange(of: model.isWaitingForApproval) { _, waiting in
            if !waiting { presentReleaseNoteIfSafe() }
        }
        .onChange(of: isEndConfirmationPresented) { _, isPresented in
            if !isPresented { presentReleaseNoteIfSafe() }
        }
        .task {
            model.restoreSavedSessionIfPossible()
            await Task.yield()
            presentReleaseNoteIfSafe()
        }
    }

    private func beginScanning() {
        pairingPresentation.discardPairingFlow()
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
        guard let sessionID = pairingPresentation.pairingSheetDidDismiss() else {
            presentReleaseNoteIfSafe()
            return
        }
        navigationPath = [conversationRoute(sessionID: sessionID)]
    }

    private func presentReleaseNoteIfSafe() {
        let context = ReleaseNotePresentationContext(
            sceneIsActive: scenePhase == .active,
            isAtHome: navigationPath.isEmpty,
            isScannerPresented: isShowingScanner,
            isAboutPresented: isShowingAbout,
            isEndConfirmationPresented: isEndConfirmationPresented,
            isBusy: model.isBusy,
            isWaitingForApproval: model.isWaitingForApproval
        )
        guard pairingPresentation.canPresentReleaseNotes(in: context),
              lastPresentedReleaseNote == nil,
              releaseNoteToPresent == nil,
              let note = releaseNotesManager.noteToShow(for: BatonAppVersion.current) else { return }
        lastPresentedReleaseNote = note
        releaseNoteToPresent = note
    }

    private func markPresentedReleaseNoteRead() {
        if let note = lastPresentedReleaseNote {
            releaseNotesManager.markRead(note)
        }
        lastPresentedReleaseNote = nil
    }
}

/// Keeps scanning and the subsequent approval wait in one modal presentation.
/// The only sheet dismissal happens after pairing resolution or explicit cancel.
private struct PairingFlowSheet: View {
    @ObservedObject var model: BatonViewModel
    let completedSessionID: String?
    let connect: (String) -> Void
    let cancelled: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasScanned = false
    @State private var selectedDetent: PresentationDetent = .large
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var pairedServiceName: String?
    @State private var pairedConversationTitle: String?

    var body: some View {
        NavigationStack {
            Group {
                if hasScanned {
                    ScrollView {
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
                        } else {
                            PairingWaitView(
                                model: model,
                                completedSessionID: completedSessionID,
                                serviceName: pairedServiceName,
                                conversationTitle: pairedConversationTitle,
                                cancel: cancel
                            )
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
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
                if completedSessionID == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(hasScanned ? "取消" : "返回") { cancel() }
                    }
                }
            }
        }
        .presentationDetents(hasScanned ? [.medium, .large] : [.large], selection: $selectedDetent)
        .onChange(of: hasScanned) { _, scanned in
            selectedDetent = scanned && !dynamicTypeSize.isAccessibilitySize ? .medium : .large
        }
        .onChange(of: dynamicTypeSize) { _, size in
            if size.isAccessibilitySize { selectedDetent = .large }
        }
        .onAppear(perform: capturePairingDetails)
        .onChange(of: model.pendingServiceName) { _, _ in capturePairingDetails() }
        .onChange(of: model.pendingConversationTitle) { _, _ in capturePairingDetails() }
        .sensoryFeedback(.success, trigger: completedSessionID) { oldValue, newValue in
            oldValue == nil && newValue != nil
        }
        .interactiveDismissDisabled(hasScanned || completedSessionID != nil)
    }

    private func cancel() {
        cancelled()
        if hasScanned { model.cancelPendingPairing() }
        dismiss()
    }

    private var pairingFailure: String? {
        guard completedSessionID == nil, hasScanned, !model.isBusy, !model.isWaitingForApproval else { return nil }
        return model.errorMessage
    }

    private func restartScanning() {
        cancelled()
        model.cancelPendingPairing()
        pairedServiceName = nil
        pairedConversationTitle = nil
        hasScanned = false
    }

    private func capturePairingDetails() {
        if let serviceName = model.pendingServiceName { pairedServiceName = serviceName }
        if let title = model.pendingConversationTitle { pairedConversationTitle = title }
    }
}

#Preview { ContentView() }
