import SwiftUI

struct ContentView: View {
    @StateObject private var model = BatonViewModel()

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
                            Button("断开本次会话", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { model.disconnect() }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            }
        }
        .task { model.restoreSavedSessionIfPossible() }
    }
}

#Preview { ContentView() }
