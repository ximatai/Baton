import SwiftUI

/// A brief orientation, not product or integration documentation. Those details
/// remain in the linked README so this sheet stays useful at the moment of scan.
struct BatonAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    intro
                    startSteps
                    documentationLink
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .navigationTitle("何为 Baton")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把网页的 Agent 对话带到手机上。")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("在各种网站服务或应用中，都会看到与 Agent 对话的窗口；但用电脑打字并不总是最方便。有时我们需要用手机实现更灵活的交流，例如语音。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("为每个 Agent 服务开发或安装一个独立 App，成本很高。Baton 定义了一组标准化协议：只要服务提供者接入协议并展示二维码，你就能用这一款 App 与不同的 Agent 服务交流。手机加入同一段对话后，消息会实时同步，网页原有功能不受影响。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("使用方式")
                .font(.headline)
            VStack(alignment: .leading, spacing: 16) {
                AboutStep(icon: "qrcode", text: "网页系统展示 Baton 接入二维码")
                AboutStep(icon: "viewfinder", text: "用 Baton 扫码加入当前对话")
                AboutStep(icon: "mic.fill", text: "语音或文字继续交流")
            }
        }
    }

    private var documentationLink: some View {
        Link(destination: URL(string: "https://github.com/ximatai/Baton")!) {
            Label("了解 Baton 与接入方式", systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct AboutStep: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .font(.body)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 22)
        }
        .accessibilityElement(children: .combine)
    }
}
