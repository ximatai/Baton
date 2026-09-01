import SwiftUI

struct MessageBubble: View {
    let message: ConversationMessage
    let imageLoader: BatonImageLoader?
    private let contentPadding: CGFloat = 10

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                MessageContentStack(message: message, imageLoader: imageLoader)
                    .padding(contentPadding)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.07)) }
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                MessageContentStack(message: message, imageLoader: imageLoader)
                    .padding(contentPadding)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

private struct MessageContentStack: View {
    let message: ConversationMessage
    let imageLoader: BatonImageLoader?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.content.isEmpty, message.status == "streaming" {
                Text("正在思考…")
            } else {
                ForEach(Array(message.content.enumerated()), id: \.offset) { _, content in
                    switch content {
                    case let .text(text):
                        if message.role == .assistant {
                            MarkdownMessageView(source: text)
                        } else {
                            Text(text).textSelection(.enabled)
                        }
                    case let .image(image):
                        RemoteMessageImageView(content: image, loader: imageLoader)
                    case let .unsupported(type, alt):
                        Label(alt ?? "此内容暂不支持（\(type)）", systemImage: "questionmark.square.dashed")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(alt ?? "此内容暂不支持，类型：\(type)")
                    }
                }
            }
        }
    }
}

struct ConversationEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text("开始这段对话").font(.headline)
            Text("输入文字，或使用麦克风在本地转写后发送。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 72)
        .accessibilityElement(children: .combine)
    }
}

struct AgentActivityNotice: View {
    let message: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            Text(message).font(.footnote.weight(.medium))
            Spacer()
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBanner: View {
    let status: String
    let isConnected: Bool
    let canReconnect: Bool
    let isUnencryptedTransport: Bool
    let reconnect: () -> Void
    @State private var isShowingUnencryptedInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status).font(.footnote).lineLimit(1)
            Spacer()
            if isUnencryptedTransport {
                Button { isShowingUnencryptedInfo = true } label: {
                    Label("未加密", systemImage: "exclamationmark.shield.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前服务使用未加密 HTTP 连接")
                .accessibilityHint("点按查看连接风险说明")
                .popover(isPresented: $isShowingUnencryptedInfo, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("未加密连接", systemImage: "exclamationmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("当前服务通过 HTTP 传输对话内容。在不可信网络中，内容可能被他人读取或篡改。")
                        Text("请仅在可信网络中继续，或让服务提供方启用 HTTPS。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
                }
            }
            if !isConnected, canReconnect { Button("重连", action: reconnect).font(.footnote.bold()) }
        }
        .foregroundStyle(isConnected ? Color.secondary : Color.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }
}

struct ErrorNotice: View {
    let text: String
    let retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer()
            if let retry {
                Button("重试", action: retry).font(.footnote.bold())
            }
        }
        .foregroundStyle(.red)
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

struct PendingOutboxMessageCard: View {
    let item: OutboxItemPresentation
    let retry: () -> Void
    let discard: () -> Void
    @State private var confirmsDiscard = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbolName)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(stateTitle).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text(item.message.text).font(.body).lineLimit(3)
            }
            Spacer(minLength: 4)
            if item.state.canRetry {
                Button("重试", action: retry).font(.footnote.bold())
            } else {
                ProgressView().controlSize(.small)
            }
            Button(role: .destructive) { confirmsDiscard = true } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("放弃待发送消息")
        }
        .padding(12)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .confirmationDialog("放弃这条待发送消息？", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("放弃消息", role: .destructive, action: discard)
        } message: {
            Text("它将从本机安全待发送箱移除。原请求可能已到达服务端，因此不能编辑后重发。")
        }
    }

    private var symbolName: String {
        switch item.state {
        case .sending: "paperplane.circle"
        case .retrying: "arrow.clockwise.circle"
        case .queued, .needsUserAction: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private var stateTitle: String {
        switch item.state {
        case .queued: "等待发送"
        case .sending: "正在发送"
        case .retrying: "正在重试"
        case .needsUserAction: "等待你重试"
        }
    }
}
