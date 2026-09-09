import SwiftUI

struct PairingWaitView: View {
    @ObservedObject var model: BatonViewModel
    let completedSessionID: String?
    let serviceName: String?
    let conversationTitle: String?
    let cancel: (() -> Void)?

    init(
        model: BatonViewModel,
        completedSessionID: String? = nil,
        serviceName: String? = nil,
        conversationTitle: String? = nil,
        cancel: (() -> Void)? = nil
    ) {
        self.model = model
        self.completedSessionID = completedSessionID
        self.serviceName = serviceName
        self.conversationTitle = conversationTitle
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                    if isCompleted {
                        Image(systemName: "checkmark")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.green)
                    } else {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.accentColor)
                    }
                }
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.title3.weight(.semibold))
                }
            }

            if displayedServiceName != nil || displayedConversationTitle != nil {
                VStack(alignment: .leading, spacing: 14) {
                    if let serviceName = displayedServiceName {
                        pairingDetail("服务", value: serviceName, symbol: "network")
                    }
                    if let title = displayedConversationTitle {
                        if displayedServiceName != nil {
                            Divider()
                        }
                        pairingDetail("对话", value: title, symbol: "bubble.left.and.bubble.right")
                    }
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if !isCompleted, cancel == nil {
                Button("取消等待", role: .cancel) { model.cancelPendingPairing() }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var isCompleted: Bool { completedSessionID != nil }
    private var isWaitingForApproval: Bool { model.isWaitingForApproval }
    private var statusColor: Color { isCompleted ? .green : .accentColor }
    private var displayedServiceName: String? { serviceName ?? model.pendingServiceName }
    private var displayedConversationTitle: String? { conversationTitle ?? model.pendingConversationTitle }

    private var statusTitle: LocalizedStringKey {
        if isCompleted { return "已加入对话" }
        if !isWaitingForApproval { return "正在建立连接" }
        return model.isAutoApprovedPairing ? "正在接入这台设备" : "等待网页确认"
    }

    private var statusMessage: LocalizedStringKey? {
        if isCompleted { return nil }
        if !isWaitingForApproval { return "正在验证二维码并连接服务，请稍候。" }
        return model.isAutoApprovedPairing
            ? "服务正在允许这台设备加入，完成后会自动进入对话。"
            : "请在显示二维码的设备上确认加入。"
    }

    private func pairingDetail(_ label: LocalizedStringKey, value: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
