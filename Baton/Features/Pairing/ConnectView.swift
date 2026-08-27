import SwiftUI

struct ConnectView: View {
    @ObservedObject var model: BatonViewModel
    @State private var pairingURL = ""
    @State private var isShowingScanner = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                VStack(alignment: .leading, spacing: 18) {
                if model.isWaitingForApproval {
                    PairingWaitView(model: model)
                } else {
                    sectionTitle("扫码加入", detail: "在网页中打开 Baton 二维码，再用手机扫描。")
                    Button { isShowingScanner = true } label: {
                        Label("扫描网页上的二维码", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                    Text("二维码只用于发起加入请求；仍需在网页确认这台设备。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #if DEBUG && targetEnvironment(simulator)
                    Divider().padding(.vertical, 2)
                    sectionTitle("本地开发", detail: "仅供当前 Debug 版本联调使用。")
                    Button { model.connectLocalDemo() } label: {
                        Label("连接本地演示服务", systemImage: "laptopcomputer.and.iphone")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    Divider().padding(.vertical, 2)
                    #endif
                    sectionTitle("粘贴 Pairing URL", detail: nil)
                    TextField("https://…/.well-known/baton/pair/…", text: $pairingURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Button("加入会话") { model.connect(pairingURL: pairingURL) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(pairingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(.primary.opacity(0.06))
                }
                if model.isBusy && !model.isWaitingForApproval {
                    ProgressView(model.connectionStatus)
                        .font(.footnote)
                }
                if let error = model.errorMessage { ErrorNotice(text: error, retry: model.retryLastConnection) }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $isShowingScanner) {
            QRScannerSheet { pairingURL in
                self.pairingURL = pairingURL
                model.connect(pairingURL: pairingURL)
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .frame(width: 82, height: 82)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text("将手机加入当前 Agent 对话")
                .font(.title2.weight(.semibold))
            Text("Baton 是同一会话的第二客户端，不是浏览器镜像。")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sectionTitle(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
