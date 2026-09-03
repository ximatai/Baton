import SwiftUI

struct ConversationView: View {
    @ObservedObject var model: BatonViewModel
    @FocusState private var isComposerFocused: Bool
    @State private var voiceVerticalDrag: CGFloat = 0
    @State private var isVoiceLongPressActive = false
    @State private var selectionScrollTask: Task<Void, Never>?

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
                        ForEach(displayedMessages) { message in
                            MessageBubble(
                                message: message,
                                imageLoader: model.imageLoader,
                                selectionStates: model.selectionStates,
                                submitSelection: model.select
                            )
                            .id(message.id)
                        }
                    }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: model.messages) { _, messages in
                    scrollToLatest(messages, using: proxy)
                }
                .onChange(of: model.selectionStates) { _, _ in
                    scrollToLatestAfterSelectionUpdate(using: proxy)
                }
                // Also scroll cached history on the destination's first appearance.
                .task(id: model.messages.last?.id) {
                    await Task.yield()
                    scrollToLatest(model.messages, using: proxy)
                }
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
                        Image(systemName: isVoiceCancellationArmed ? "xmark.circle.fill" : model.voiceState.isRecording ? "waveform" : "mic.slash")
                        if model.voiceState.isRecording {
                            Text(isVoiceCancellationArmed ? "松开取消本次听写" : "正在听写，上滑取消，松开转写")
                                .font(.footnote)
                                .foregroundStyle(isVoiceCancellationArmed ? .orange : Color.accentColor)
                        }
                        else { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        if !model.voiceState.isWorking { Spacer(); Button("知道了") { model.dismissVoiceIssue() }.font(.footnote.bold()) }
                    }.padding(.horizontal, 4)
                }
                if let message = model.composerUnavailableMessage {
                    Label(message, systemImage: model.composerUnavailableSymbolName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                HStack(alignment: .center, spacing: 10) {
                    ZStack(alignment: .leading) {
                        if composerPlaceholder != nil {
                            voiceInputPlaceholder
                                .allowsHitTesting(false)
                        }
                        TextField(
                            "",
                            text: $model.composerText,
                            axis: .vertical
                        )
                            .lineLimit(1...5)
                            .focused($isComposerFocused)
                            .submitLabel(.send)
                            .onSubmit { model.send() }
                            .disabled(model.isComposerDisabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(composerBorderColor, lineWidth: isVoiceLongPressActive ? 1.5 : 1)
                    }
                    .simultaneousGesture(
                        LongPressGesture(
                            minimumDuration: 0.25,
                            maximumDistance: .greatestFiniteMagnitude
                        )
                        .onChanged { _ in
                            voiceVerticalDrag = 0
                            beginVoiceInputFromLongPress()
                        }
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard isVoiceLongPressActive else { return }
                                voiceVerticalDrag = value.translation.height
                            }
                            .onEnded { _ in
                                guard isVoiceLongPressActive else { return }
                                finishVoiceInputGesture()
                            }
                    )
                    .accessibilityHint("轻点输入文字；长按开始本地语音转文字，上滑取消，松开后可编辑转写结果")
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
        model.beginVoiceInput()
    }

    private func beginVoiceInputFromLongPress() {
        guard !isVoiceLongPressActive else { return }
        isVoiceLongPressActive = true
        beginVoiceInput()
    }

    private func finishVoiceInputGesture() {
        if voiceVerticalDrag < -44 {
            model.cancelVoiceInput()
        } else {
            model.endVoiceInput()
        }
        voiceVerticalDrag = 0
        isVoiceLongPressActive = false
    }

    private var isVoiceCancellationArmed: Bool {
        isVoiceLongPressActive && model.voiceState.isWorking && voiceVerticalDrag < -44
    }

    @ViewBuilder
    private var voiceInputPlaceholder: some View {
        if let unavailableMessage = model.composerUnavailableMessage, !model.isSelectionRequired {
            Text(unavailableMessage)
                .foregroundStyle(.secondary)
        } else if !model.isComposerDisabled {
            HStack(spacing: 0) {
                Text("按住 ")
                    .foregroundStyle(.secondary)
                Text("转文字")
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var composerPlaceholder: String? {
        model.composerText.isEmpty ? "" : nil
    }

    private var displayedMessages: [ConversationMessage] {
        model.messages.filter { !shouldHideResolvedSelectionResponse($0) }
    }

    private var selectionCardIDs: Set<String> {
        Set(model.messages
            .filter { $0.role == .assistant }
            .flatMap { message in
                message.content.compactMap { content in
                    guard case let .selection(selection) = content else { return nil }
                    return selection.interactionID
                }
            })
    }

    private func shouldHideResolvedSelectionResponse(_ message: ConversationMessage) -> Bool {
        guard message.role == .user,
              message.content.count == 1,
              case let .selectionResponse(response) = message.content[0],
              selectionCardIDs.contains(response.interactionID),
              model.selectionStates[response.interactionID]?.status == .answered else {
            return false
        }
        return true
    }

    private func scrollToLatestAfterSelectionUpdate(using proxy: ScrollViewProxy) {
        selectionScrollTask?.cancel()
        let targetID = displayedMessages.last?.id
        selectionScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let targetID else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(targetID, anchor: .bottom)
            }
        }
    }

    private var composerBorderColor: Color {
        if isVoiceCancellationArmed { return .orange }
        if isVoiceLongPressActive { return Color.accentColor }
        return .primary.opacity(0.12)
    }

    @MainActor
    private func scrollToLatest(_ messages: [ConversationMessage], using proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }
}
