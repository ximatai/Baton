import SwiftUI

struct ConversationView: View {
    @ObservedObject var model: BatonViewModel
    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(status: model.connectionStatus, isConnected: model.isConnected, reconnect: model.reconnect)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.messages) { message in MessageBubble(message: message).id(message.id) }
                    }.padding()
                }.onChange(of: model.messages) { _, messages in if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let error = model.errorMessage { ErrorNotice(text: error, retry: model.reconnect) }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let message = model.voiceState.message {
                    HStack(spacing: 6) {
                        if model.voiceState.isWorking && !model.voiceState.isRecording { ProgressView().controlSize(.small) }
                        Image(systemName: model.voiceState.isRecording ? "waveform" : "mic.slash")
                        if model.voiceState.isRecording { Text(message).font(.footnote).foregroundStyle(.tint) }
                        else { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        if !model.voiceState.isWorking { Spacer(); Button("知道了") { model.dismissVoiceIssue() }.font(.footnote.bold()) }
                    }.padding(.horizontal, 4)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("输入消息", text: $model.composerText, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { model.send() }
                    Button { model.toggleVoiceInput() } label: { Image(systemName: model.voiceState.isRecording ? "stop.circle.fill" : "mic.circle.fill").font(.title2) }
                        .disabled(model.voiceState.isWorking && !model.voiceState.isRecording)
                        .accessibilityLabel(model.voiceState.isRecording ? "停止语音输入" : "开始语音输入")
                    if let runID = model.activeRunID {
                        Button { model.cancel(runID: runID) } label: { Image(systemName: "stop.fill") }.buttonStyle(.bordered).accessibilityLabel("停止生成")
                    } else {
                        Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.disabled(!model.canSend).accessibilityLabel("发送")
                    }
                }
            }.padding()
        }
    }
}
