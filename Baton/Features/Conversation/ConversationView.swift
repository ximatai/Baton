import SwiftUI

struct ConversationView: View {
    @ObservedObject var model: BatonViewModel
    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(
                status: model.connectionStatus,
                isConnected: model.isConnected,
                isUnencryptedTransport: model.isUnencryptedTransport,
                reconnect: model.reconnect
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if model.messages.isEmpty { ConversationEmptyState() }
                        ForEach(model.messages) { message in MessageBubble(message: message).id(message.id) }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: model.messages) { _, messages in if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let error = model.errorMessage { ErrorNotice(text: error, retry: model.reconnect) }
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 6) {
                if let message = model.agentActivity.message {
                    AgentActivityNotice(message: message, symbolName: model.agentActivity.symbolName)
                }
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
                    TextField("输入消息", text: $model.composerText, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.12)) }
                        .submitLabel(.send)
                        .onSubmit { model.send() }
                    Button { model.toggleVoiceInput() } label: {
                        Image(systemName: model.voiceState.isRecording ? "stop.fill" : "mic.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.bordered)
                    .tint(model.voiceState.isRecording ? .red : .accentColor)
                        .disabled(model.voiceState.isWorking && !model.voiceState.isRecording)
                        .accessibilityLabel(model.voiceState.isRecording ? "停止语音输入" : "开始语音输入")
                    if let runID = model.activeRunID {
                        Button { model.cancel(runID: runID) } label: { Image(systemName: "stop.fill").frame(width: 22, height: 22) }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .accessibilityLabel("停止生成")
                    } else {
                        Button { model.send() } label: { Image(systemName: "arrow.up").frame(width: 22, height: 22) }
                            .buttonStyle(.borderedProminent)
                            .clipShape(Circle())
                            .disabled(!model.canSend)
                            .accessibilityLabel("发送")
                    }
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }
}
