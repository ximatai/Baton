import SwiftUI

struct MessageBubble: View {
    let message: ConversationMessage
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                MarkdownMessageView(source: message.text.isEmpty && message.status == "streaming" ? "正在思考…" : message.text)
                    .padding(13)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.07)) }
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(13)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .accessibilityLabel(message.role == .assistant ? "助手：\(message.text)" : "我：\(message.text)")
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
    let status: String; let isConnected: Bool; let reconnect: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status).font(.footnote).lineLimit(1)
            Spacer()
            if !isConnected { Button("重连", action: reconnect).font(.footnote.bold()) }
        }
        .foregroundStyle(isConnected ? Color.secondary : Color.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }
}

struct ErrorNotice: View {
    let text: String; let retry: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer()
            Button("重试", action: retry).font(.footnote.bold())
        }
        .foregroundStyle(.red)
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}
