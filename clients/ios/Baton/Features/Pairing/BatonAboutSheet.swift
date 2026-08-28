import SwiftUI

/// This sheet is user-facing. Product and integration detail belongs in the
/// linked README; here we help someone decide what to do next.
struct BatonAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    howItWorks
                    whatBatonDoes
                    safetyNote
                    documentationLink
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
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

    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text("把网页中的对话，接到手机上继续说。")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("当电脑上的 Agent 对话不方便打字时，用 Baton 扫码加入同一段对话。你可以在手机上语音输入、修改文字并发送；网页仍保留原有的业务界面。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("如何开始")
                .font(.headline)
            VStack(spacing: 0) {
                GuideStep(number: "1", title: "在网页打开一段 Agent 对话", detail: "让网页显示 Baton 二维码。")
                Divider().padding(.leading, 42)
                GuideStep(number: "2", title: "在这里扫描二维码", detail: "经网页确认后，手机会加入当前对话。")
                Divider().padding(.leading, 42)
                GuideStep(number: "3", title: "用语音或文字继续交流", detail: "发送的消息会回到同一段网页对话。")
            }
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08))
            }
        }
    }

    private var whatBatonDoes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Baton 的角色")
                .font(.headline)
            Text("Baton 不是浏览器镜像，也不替代你的业务系统。登录、权限、会话和 Agent 仍由原来的网页服务负责；Baton 只是一个随时可加入的手机端。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var safetyNote: some View {
        Label {
            Text("请只扫描可信网页提供的二维码。若服务使用未加密连接，进入对话后会明确提示。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.tint)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var documentationLink: some View {
        Link(destination: URL(string: "https://github.com/ximatai/Baton")!) {
            Label("了解 Baton 与接入方式", systemImage: "arrow.up.right.square")
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct GuideStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}
