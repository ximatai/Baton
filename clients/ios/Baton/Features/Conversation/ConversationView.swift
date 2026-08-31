import SwiftUI

struct ConversationView: View {
    @ObservedObject var model: BatonViewModel
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(
                status: model.connectionStatus,
                isConnected: model.isConnected,
                canReconnect: true,
                isUnencryptedTransport: model.isUnencryptedTransport,
                reconnect: model.reconnect
            )
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        if model.messages.isEmpty { ConversationEmptyState() }
                        ForEach(model.messages) { message in MessageBubble(message: message, imageLoader: model.imageLoader).id(message.id) }
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
            if let error = model.errorMessage {
                ErrorNotice(text: error, retry: { model.reconnect() })
            }
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
                HStack(alignment: .center, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        TextField("输入消息", text: $model.composerText, axis: .vertical)
                            .lineLimit(1...5)
                            .focused($isComposerFocused)
                            .submitLabel(.send)
                            .onSubmit { model.send() }
                        Image(systemName: model.voiceState.isRecording ? "waveform" : "mic")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(
                                model.voiceState.isRecording ? .red : Color.accentColor
                            )
                            .frame(width: 28, height: 28)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.12)) }
                    .onLongPressGesture(
                        minimumDuration: 0.35,
                        maximumDistance: 32,
                        perform: beginVoiceInput,
                        onPressingChanged: { isPressing in
                            if !isPressing { model.endVoiceInput() }
                        }
                    )
                    .accessibilityHint("长按开始本地语音输入，松开后可编辑转写结果")
                    .accessibilityAction(named: model.voiceState.isWorking ? "结束语音输入" : "开始语音输入") {
                        if model.voiceState.isWorking {
                            model.endVoiceInput()
                        } else {
                            beginVoiceInput()
                        }
                    }
                    .disabled(model.isComposerDisabled)
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

    private func beginVoiceInput() {
        isComposerFocused = false
        model.beginVoiceInput()
    }
}
