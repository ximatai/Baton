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
                    Text("Baton 是同一段对话的手机端；网页仍保留原有的业务界面。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    documentationLink
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .navigationTitle("使用 Baton")
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
            Text("需要输入时扫码加入当前对话：手机适合语音，网页继续保留完整工作区。")
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
                AboutStep(icon: "qrcode", text: "网页显示 Baton 二维码")
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
