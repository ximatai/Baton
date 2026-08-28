import SwiftUI

struct BatonAboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let content = """
    # Baton

    Baton 是已有 Web 与 Agent 会话的 iOS Companion，让用户通过扫码，把手机加入正在进行的对话。

    业务系统仍然负责登录、权限、会话与 Agent；Baton 不是浏览器镜像，也不要求替换既有 Web 系统。它让手机成为更自然的语音优先输入端，同时与 Web 共享同一段 Conversation。

    [查看 GitHub 上的协议、接入与联调文档](https://github.com/ximatai/Baton)
    """

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownMessageView(source: content)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle("关于 Baton")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
