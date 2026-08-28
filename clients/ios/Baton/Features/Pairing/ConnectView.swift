import SwiftUI

struct ConnectView: View {
    private struct PendingSessionAction: Identifiable {
        enum Kind { case disconnect, end }
        let session: ConversationSessionSummary
        let kind: Kind
        var id: String { "\(kind)-\(session.id)" }
    }

    @ObservedObject var model: BatonViewModel
    let scan: () -> Void
    let openSession: (String) -> Void
    @State private var pendingSessionAction: PendingSessionAction?

    var body: some View {
        Group {
            if model.savedSessions.isEmpty {
                VStack(spacing: 20) {
                    Spacer()
                    emptyState
                    if let error = model.errorMessage {
                        ErrorNotice(text: error, retry: model.retryLastConnection)
                    }
                    Spacer()
                }
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List {
                    Section("已加入的会话") {
                        ForEach(model.savedSessions) { session in
                            Button { openSession(session.id) } label: {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: session))
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                Button {
                                    Task { await model.refreshSessionAvailability(sessionID: session.id) }
                                } label: {
                                    Label("检查", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    pendingSessionAction = PendingSessionAction(session: session, kind: .end)
                                } label: {
                                    Label("结束", systemImage: "xmark.circle")
                                }
                                Button {
                                    pendingSessionAction = PendingSessionAction(session: session, kind: .disconnect)
                                } label: {
                                    Label("断开", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                                .tint(.orange)
                            }
                        }
                    }
                    if let error = model.errorMessage {
                        Section { ErrorNotice(text: error, retry: model.retryLastConnection) }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await model.refreshSessionAvailability()
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingSessionAction != nil },
                set: { if !$0 { pendingSessionAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingSessionAction {
                Button(confirmationButtonTitle, role: .destructive) {
                    switch action.kind {
                    case .disconnect: model.disconnectSavedSession(id: action.session.id)
                    case .end: model.endSavedSession(id: action.session.id)
                    }
                    pendingSessionAction = nil
                }
            }
            Button("取消", role: .cancel) { pendingSessionAction = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var emptyState: some View {
        Group {
            if model.isWaitingForApproval {
                PairingWaitView(model: model)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 80, height: 80)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text("扫码加入对话")
                    .font(.title2.weight(.semibold))
                Text("扫描网页上的 Baton 二维码")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button(action: scan) {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isBusy)
                if model.isBusy {
                    ProgressView(model.connectionStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #if DEBUG && targetEnvironment(simulator)
                Button("连接本地演示服务") { model.connectLocalDemo() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                #endif
            }
        }
    }

    private func sessionRow(_ session: ConversationSessionSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.conversation.title).lineLimit(1)
                Text(session.service.name)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            availabilityIndicator(for: session.id)
        }
        .contentShape(Rectangle())
    }

    private func accessibilityLabel(for session: ConversationSessionSummary) -> String {
        var result = "\(session.conversation.title)，\(session.service.name)"
        switch model.availability(for: session.id) {
        case .checking: result += "，正在检查可用性"
        case .available: result += "，可用"
        case .unavailable: result += "，当前不可用"
        case nil: break
        }
        return result
    }

    private var confirmationTitle: String {
        switch pendingSessionAction?.kind {
        case .disconnect: "断开本机访问？"
        case .end: "结束这段对话？"
        case nil: ""
        }
    }

    private var confirmationButtonTitle: String {
        switch pendingSessionAction?.kind {
        case .disconnect: "断开"
        case .end: "结束对话"
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch pendingSessionAction?.kind {
        case .disconnect: "将撤销这台设备访问“\(pendingSessionAction?.session.conversation.title ?? "")”的权限，并从列表移除。"
        case .end: "所有已加入“\(pendingSessionAction?.session.conversation.title ?? "")”的设备都会退出。"
        case nil: ""
        }
    }

    @ViewBuilder
    private func availabilityIndicator(for sessionID: String) -> some View {
        switch model.availability(for: sessionID) {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("正在检查可用性")
        case .available:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("可用")
        case .unavailable:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("当前不可用")
        case nil:
            EmptyView()
        }
    }

}
