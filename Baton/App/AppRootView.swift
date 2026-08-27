import SwiftUI

struct ContentView: View {
    @StateObject private var model = BatonViewModel()
    @State private var isEndConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Group {
                if model.conversation != nil { ConversationView(model: model) }
                else { ConnectView(model: model) }
            }
            .navigationTitle(model.conversation?.title ?? "Baton")
            .toolbar {
                if model.conversation != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("重新连接", systemImage: "arrow.clockwise") { model.reconnect() }
                            Button("结束对话", systemImage: "xmark.circle", role: .destructive) { isEndConfirmationPresented = true }
                            Button("断开本次会话", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.disconnect() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .confirmationDialog("结束当前对话？", isPresented: $isEndConfirmationPresented, titleVisibility: .visible) {
            Button("结束对话", role: .destructive) { model.endConversation() }
        } message: {
            Text("所有已加入这段对话的设备都会退出。")
        }
        .task { model.restoreSavedSessionIfPossible() }
    }
}

#Preview { ContentView() }
