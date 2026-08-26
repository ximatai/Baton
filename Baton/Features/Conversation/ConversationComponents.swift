import SwiftUI

struct MessageBubble: View {
    let message: ConversationMessage
    var body: some View {
        HStack {
            if message.role == .assistant {
                MarkdownMessageView(source: message.text.isEmpty && message.status == "streaming" ? "正在思考…" : message.text).padding(12).background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48); Text(message.text).textSelection(.enabled).padding(12).foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
        }.accessibilityLabel(message.role == .assistant ? "助手：\(message.text)" : "我：\(message.text)")
    }
}

struct ConnectionBanner: View {
    let status: String; let isConnected: Bool; let reconnect: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isConnected ? "dot.radiowaves.left.and.right" : "wifi.exclamationmark"); Text(status).font(.footnote); Spacer()
            if !isConnected { Button("重连", action: reconnect).font(.footnote.bold()) }
        }.foregroundStyle(isConnected ? Color.secondary : Color.orange).padding(.horizontal).padding(.vertical, 8).background(.thinMaterial)
    }
}

struct ErrorNotice: View {
    let text: String; let retry: () -> Void
    var body: some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(text).font(.footnote); Spacer(); Button("重试", action: retry).font(.footnote.bold()) }
            .foregroundStyle(.red).padding(10).background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal)
    }
}
