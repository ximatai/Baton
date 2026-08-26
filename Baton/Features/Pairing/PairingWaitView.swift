import SwiftUI

struct PairingWaitView: View {
    @ObservedObject var model: BatonViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 3) {
                    Text("等待网页确认").font(.headline)
                    Text(model.pendingServiceName ?? "正在连接服务").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let title = model.pendingConversationTitle {
                Label(title, systemImage: "bubble.left.and.bubble.right").font(.footnote).foregroundStyle(.secondary)
            }
            Text("请在浏览器中确认这台设备的加入请求。确认前不会保存会话凭据。").font(.footnote).foregroundStyle(.secondary)
            if let approvalURL = model.pendingApprovalURL {
                Link(destination: approvalURL) {
                    Label("打开网页确认页", systemImage: "safari").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("在服务端网页中确认或拒绝此设备请求")
            }
            Button("取消等待", role: .cancel) { model.cancelPendingPairing() }.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
