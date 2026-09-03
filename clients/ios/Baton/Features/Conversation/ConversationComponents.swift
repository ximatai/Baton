import SwiftUI

struct MessageBubble: View {
    let message: ConversationMessage
    let imageLoader: BatonImageLoader?
    let selectionStates: [String: SelectionInteractionState]
    let submitSelection: (MessageSelection, MessageSelectionOption) -> Void
    private let contentPadding: CGFloat = 10
    private var isStandaloneSelection: Bool {
        guard message.role == .assistant, message.content.count == 1,
              case .selection = message.content[0] else { return false }
        return true
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                MessageContentStack(message: message, imageLoader: imageLoader, selectionStates: selectionStates, submitSelection: submitSelection, selectionFillsMessageBubble: isStandaloneSelection)
                    .padding(isStandaloneSelection ? 0 : contentPadding)
                    .background(isStandaloneSelection ? Color.clear : Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(isStandaloneSelection ? Color.clear : Color.primary.opacity(0.07)) }
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                MessageContentStack(message: message, imageLoader: imageLoader, selectionStates: selectionStates, submitSelection: submitSelection, selectionFillsMessageBubble: false)
                    .padding(contentPadding)
                    .foregroundStyle(.white)
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }
}

private struct MessageContentStack: View {
    let message: ConversationMessage
    let imageLoader: BatonImageLoader?
    let selectionStates: [String: SelectionInteractionState]
    let submitSelection: (MessageSelection, MessageSelectionOption) -> Void
    let selectionFillsMessageBubble: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if message.content.isEmpty, message.status == "streaming" {
                Text("正在思考…")
            } else {
                ForEach(Array(message.content.enumerated()), id: \.offset) { offset, content in
                    switch content {
                    case let .text(text):
                        if message.role == .assistant {
                            MarkdownMessageView(source: text)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    case .image:
                        if isImageRunStart(at: offset) {
                            let images = imageRun(startingAt: offset)
                            if images.count == 1, let image = images.first {
                                RemoteMessageImageView(content: image, loader: imageLoader)
                            } else {
                                MessageImageGrid(
                                    images: images,
                                    siblings: message.content.compactMap(\.image),
                                    loader: imageLoader
                                )
                            }
                        }
                    case let .selection(selection):
                        SelectionCard(
                            selection: selection,
                            state: selectionStates[selection.interactionID],
                            fillsMessageBubble: selectionFillsMessageBubble,
                            submit: { option in submitSelection(selection, option) }
                        )
                    case let .selectionResponse(response):
                        Label(response.label.map { String(format: String(localized: "已选择：%@"), $0) } ?? String(localized: "已完成选择"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                    case let .unsupported(type, alt):
                        Label(alt ?? "此内容暂不支持（\(type)）", systemImage: "questionmark.square.dashed")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(alt ?? "此内容暂不支持，类型：\(type)")
                    }
                }
            }
        }
    }

    private func isImageRunStart(at index: Int) -> Bool {
        index == 0 || message.content[index - 1].image == nil
    }

    private func imageRun(startingAt index: Int) -> [MessageImage] {
        message.content[index...].prefix { $0.image != nil }.compactMap(\.image)
    }
}

private struct SelectionCard: View {
    let selection: MessageSelection
    let state: SelectionInteractionState?
    let fillsMessageBubble: Bool
    let submit: (MessageSelectionOption) -> Void

    private var isOpen: Bool { state?.status == .open }
    private var requiresSelection: Bool { selection.inputPolicy == .selectionRequired }
    private var backgroundColor: Color {
        requiresSelection ? .orange.opacity(0.13) : Color.accentColor.opacity(0.08)
    }

    var body: some View {
        Group {
            if let state, state.status != .open {
                Label(selectionStatusText(state), systemImage: selectionStatusSymbol(state))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(selection.prompt)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if selection.presentation == .confirmation {
                        HStack(spacing: 8) {
                            ForEach(selection.options) { option in
                                selectionButton(option)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                ForEach(selection.options) { option in
                                    selectionButton(option, keepsLabelOnOneLine: true)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(selection.options) { option in
                                    selectionButton(option)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(fillsMessageBubble ? 14 : 10)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: fillsMessageBubble ? 18 : 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: fillsMessageBubble ? 18 : 12, style: .continuous).strokeBorder(fillsMessageBubble ? Color.primary.opacity(0.07) : Color.clear) }
        .accessibilityLabel(requiresSelection ? "需要完成选择：\(selection.prompt)" : selection.prompt)
    }

    private func selectionStatusText(_ state: SelectionInteractionState) -> String {
        switch state.status {
        case .open: return ""
        case .answered:
            guard let optionID = state.selectedOptionID,
                  let option = selection.options.first(where: { $0.id == optionID }) else {
                return String(localized: "已完成选择")
            }
            return String(format: String(localized: "已选择：%@"), option.label)
        case .cancelled: return String(localized: "此选择已取消")
        case .superseded: return String(localized: "此选择已更新")
        case .expired: return String(localized: "此选择已过期")
        }
    }

    private func selectionStatusSymbol(_ state: SelectionInteractionState) -> String {
        switch state.status {
        case .answered:
            if selection.presentation == .confirmation, state.selectedOptionID == "cancel" {
                return "xmark.circle.fill"
            }
            return "checkmark.circle.fill"
        case .cancelled, .superseded, .expired: return "minus.circle"
        case .open: return "circle"
        }
    }

    private func isConfirmationAction(_ option: MessageSelectionOption) -> Bool {
        selection.presentation == .confirmation && option.id == "confirm"
    }

    @ViewBuilder
    private func selectionButton(_ option: MessageSelectionOption, keepsLabelOnOneLine: Bool = false) -> some View {
        if isConfirmationAction(option) {
            Button { submit(option) } label: {
                Text(option.label)
                    .fixedSize(horizontal: keepsLabelOnOneLine, vertical: false)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isOpen)
            .accessibilityHint(isOpen ? "点按后立即发送" : "此选择已结束")
        } else {
            Button { submit(option) } label: {
                Text(option.label)
                    .fixedSize(horizontal: keepsLabelOnOneLine, vertical: false)
            }
            .buttonStyle(.bordered)
            .disabled(!isOpen)
            .accessibilityHint(isOpen ? "点按后立即发送" : "此选择已结束")
        }
    }
}

private struct MessageImageGrid: View {
    let images: [MessageImage]
    let siblings: [MessageImage]
    let loader: BatonImageLoader?
    @State private var selectedMediaID: String?

    // Keep a multi-image message compact: each rendition preserves its aspect
    // ratio inside this visual ceiling, then the grid wraps siblings to rows.
    private let thumbnailHeight: CGFloat = 132
    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 168), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(images) { image in
                RemoteMessageImageView(
                    content: image,
                    loader: loader,
                    maximumHeight: thumbnailHeight,
                    openGallery: { selectedMediaID = image.mediaID }
                )
                .frame(height: thumbnailHeight)
            }
        }
        .sheet(
            isPresented: Binding(
                get: { selectedMediaID != nil },
                set: { if !$0 { selectedMediaID = nil } }
            )
        ) {
            if let selectedMediaID {
                MessageImageGallery(images: siblings, loader: loader, initialMediaID: selectedMediaID)
            }
        }
    }
}

struct ConversationEmptyState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text("开始这段对话").font(.headline)
            Text("输入文字，或使用麦克风在本地转写后发送。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 72)
        .accessibilityElement(children: .combine)
    }
}

struct AgentActivityNotice: View {
    let message: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)
            Text(message).font(.footnote.weight(.medium))
            Spacer()
        }
        .foregroundStyle(.tint)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ConnectionBanner: View {
    let status: String
    let isConnected: Bool
    let canReconnect: Bool
    let isUnencryptedTransport: Bool
    let reconnect: () -> Void
    @State private var isShowingUnencryptedInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status).font(.footnote).lineLimit(1)
            Spacer()
            if isUnencryptedTransport {
                Button { isShowingUnencryptedInfo = true } label: {
                    Label("未加密", systemImage: "exclamationmark.shield.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前服务使用未加密 HTTP 连接")
                .accessibilityHint("点按查看连接风险说明")
                .popover(isPresented: $isShowingUnencryptedInfo, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("未加密连接", systemImage: "exclamationmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("当前服务通过 HTTP 传输对话内容。在不可信网络中，内容可能被他人读取或篡改。")
                        Text("请仅在可信网络中继续，或让服务提供方启用 HTTPS。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(16)
                    .presentationCompactAdaptation(.popover)
                }
            }
            if !isConnected, canReconnect { Button("重连", action: reconnect).font(.footnote.bold()) }
        }
        .foregroundStyle(isConnected ? Color.secondary : Color.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.thinMaterial)
    }
}

struct ErrorNotice: View {
    let text: String
    let retry: (() -> Void)?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.footnote)
            Spacer()
            if let retry {
                Button("重试", action: retry).font(.footnote.bold())
            }
        }
        .foregroundStyle(.red)
        .padding(12)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}
