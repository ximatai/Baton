import SwiftUI

struct ConnectView: View {
    /// The collection identity stays the Conversation key. The rendered row
    /// additionally changes identity when pinning changes, so List does not
    /// try to move a still-open UIKit swipe cell to its new position.
    private struct SessionRowIdentity: Hashable {
        let conversationKey: String
        let isPinned: Bool
    }

    private struct PendingSessionAction: Identifiable {
        enum Kind { case disconnect }
        let session: ConversationSessionSummary
        let kind: Kind
        var id: String { "\(kind)-\(session.id)" }
    }

    @ObservedObject var model: BatonViewModel
    let scan: () -> Void
    let openSession: (String) -> Void
    @State private var pendingSessionAction: PendingSessionAction?
    @State private var sessionBeingRenamed: ConversationSessionSummary?
    @State private var renameTitle = ""

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
                    Section {
                        ForEach(model.savedSessions) { session in
                            Button { openSession(session.id) } label: {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(accessibilityLabel(for: session))
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                pinAction(for: session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                renameAction(for: session)
                                disconnectAction(for: session)
                            }
                            .id(SessionRowIdentity(conversationKey: session.id, isPinned: session.isPinned))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await model.refreshSessionAvailability()
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .alert(
            "断开本机访问？",
            isPresented: Binding(
                get: { pendingSessionAction != nil },
                set: { if !$0 { pendingSessionAction = nil } }
            )
        ) {
            if let action = pendingSessionAction {
                Button("断开", role: .destructive) {
                    switch action.kind {
                    case .disconnect: model.disconnectSavedSession(id: action.session.id)
                    }
                    pendingSessionAction = nil
                }
            }
            Button("取消", role: .cancel) { pendingSessionAction = nil }
        } message: {
            Text(confirmationMessage)
        }
        .alert(
            "重命名对话",
            isPresented: Binding(
                get: { sessionBeingRenamed != nil },
                set: { if !$0 { sessionBeingRenamed = nil } }
            )
        ) {
            TextField("对话名称", text: $renameTitle)
            Button("保存") {
                if let sessionBeingRenamed {
                    model.renameSavedSession(id: sessionBeingRenamed.id, title: renameTitle)
                }
                sessionBeingRenamed = nil
            }
            Button("取消", role: .cancel) { sessionBeingRenamed = nil }
        } message: {
            Text("仅修改该对话在这台 iPhone 上的展示名称。")
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
                HStack(spacing: 6) {
                    Text(session.displayTitle).lineLimit(1)
                    if session.hasUnreadUpdates {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel("有更新")
                    }
                }
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
        var result = "\(session.displayTitle)，\(session.service.name)"
        if session.hasUnreadUpdates { result += "，有更新" }
        switch model.availability(for: session.id) {
        case .checking: result += "，正在检查可用性"
        case .available: result += "，可用"
        case .unavailable: result += "，当前不可用"
        case nil: break
        }
        return result
    }

    private func disconnectAction(for session: ConversationSessionSummary) -> some View {
        Button {
            pendingSessionAction = PendingSessionAction(session: session, kind: .disconnect)
        } label: {
            Image(systemName: "rectangle.portrait.and.arrow.right")
        }
        .tint(.orange)
        .accessibilityLabel("断开本机访问")
    }

    private func renameAction(for session: ConversationSessionSummary) -> some View {
        Button {
            renameTitle = session.displayTitle
            sessionBeingRenamed = session
        } label: {
            Image(systemName: "pencil")
        }
        .tint(.indigo)
        .accessibilityLabel("重命名对话")
    }

    private func pinAction(for session: ConversationSessionSummary) -> some View {
        Button {
            withAnimation(.snappy) {
                model.setSavedSessionPinned(id: session.id, pinned: !session.isPinned)
            }
        } label: {
            Image(systemName: session.isPinned ? "pin.slash" : "pin")
        }
        .tint(session.isPinned ? .gray : .yellow)
        .accessibilityLabel(session.isPinned ? "取消置顶" : "置顶")
    }

    private var confirmationMessage: String {
        switch pendingSessionAction?.kind {
        case .disconnect: "将从这台 iPhone 断开此对话。"
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
