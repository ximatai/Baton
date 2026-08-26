//
//  ContentView.swift
//  Baton
//
//  Created by 牧云踏歌 on 2026/8/26.
//

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

private struct ConnectView: View {
    @ObservedObject var model: BatonViewModel
    @State private var pairingURL = ""
    @State private var isShowingScanner = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 52, weight: .light)).foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("将手机加入当前 Agent 对话").font(.title3.bold())
                Text("Baton 是同一会话的第二客户端，不是浏览器镜像。").multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                if model.isWaitingForApproval {
                    PairingWaitView(model: model)
                } else {
                    Text("扫码加入").font(.headline)
                    Button {
                        isShowingScanner = true
                    } label: {
                        Label("扫描网页上的二维码", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)

                    Text("二维码只用于发起加入请求；仍需在网页确认这台设备。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Divider().padding(.vertical, 4)
                    #if DEBUG
                    Text("本地开发").font(.headline)
                    Button { model.connectLocalDemo() } label: {
                        Label("连接本地演示服务", systemImage: "laptopcomputer.and.iphone").frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(model.isBusy)
                    Divider().padding(.vertical, 4)
                    #endif
                    Text("粘贴 Pairing URL").font(.headline)
                    TextField("https://…/.well-known/baton/pair/…", text: $pairingURL, axis: .vertical)
                        .textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    Button("加入会话") { model.connect(pairingURL: pairingURL) }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(pairingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
            }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal)
            if model.isBusy && !model.isWaitingForApproval { ProgressView(model.connectionStatus) }
            if let error = model.errorMessage { ErrorNotice(text: error, retry: model.retryLastConnection) }
            Spacer()
        }
        .padding()
        .sheet(isPresented: $isShowingScanner) {
            QRScannerSheet { pairingURL in
                self.pairingURL = pairingURL
                model.connect(pairingURL: pairingURL)
            }
        }
    }
}

private struct PairingWaitView: View {
    @ObservedObject var model: BatonViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: 3) {
                    Text("等待网页确认").font(.headline)
                    Text(model.pendingServiceName ?? "正在连接服务")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let title = model.pendingConversationTitle {
                Label(title, systemImage: "bubble.left.and.bubble.right")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("请在浏览器中确认这台设备的加入请求。确认前不会保存会话凭据。")
                .font(.footnote).foregroundStyle(.secondary)
            if let approvalURL = model.pendingApprovalURL {
                Link(destination: approvalURL) {
                    Label("打开网页确认页", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("在服务端网页中确认或拒绝此设备请求")
            }
            Button("取消等待", role: .cancel) { model.cancelPendingPairing() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct ConversationView: View {
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
                        if model.voiceState.isRecording {
                            Text(message).font(.footnote).foregroundStyle(.tint)
                        } else {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        if !model.voiceState.isWorking {
                            Spacer()
                            Button("知道了") { model.dismissVoiceIssue() }.font(.footnote.bold())
                        }
                    }
                    .padding(.horizontal, 4)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("输入消息", text: $model.composerText, axis: .vertical).lineLimit(1...5).textFieldStyle(.roundedBorder).submitLabel(.send).onSubmit { model.send() }
                    Button { model.toggleVoiceInput() } label: {
                        Image(systemName: model.voiceState.isRecording ? "stop.circle.fill" : "mic.circle.fill").font(.title2)
                    }
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

private struct MessageBubble: View {
    let message: ConversationMessage
    var body: some View {
        HStack {
            if message.role == .assistant {
                MarkdownMessageView(source: message.text.isEmpty && message.status == "streaming" ? "正在思考…" : message.text)
                    .padding(12)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48); Text(message.text).textSelection(.enabled).padding(12).foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
        }.accessibilityLabel(message.role == .assistant ? "助手：\(message.text)" : "我：\(message.text)")
    }
}

private struct ConnectionBanner: View {
    let status: String; let isConnected: Bool; let reconnect: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isConnected ? "dot.radiowaves.left.and.right" : "wifi.exclamationmark"); Text(status).font(.footnote); Spacer()
            if !isConnected { Button("重连", action: reconnect).font(.footnote.bold()) }
        }.foregroundStyle(isConnected ? Color.secondary : Color.orange).padding(.horizontal).padding(.vertical, 8).background(.thinMaterial)
    }
}

private struct ErrorNotice: View {
    let text: String; let retry: () -> Void
    var body: some View {
        HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(text).font(.footnote); Spacer(); Button("重试", action: retry).font(.footnote.bold()) }
            .foregroundStyle(.red).padding(10).background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal)
    }
}

#Preview { ContentView() }
