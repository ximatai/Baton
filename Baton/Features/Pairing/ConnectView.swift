import SwiftUI

struct ConnectView: View {
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
                    Button { isShowingScanner = true } label: {
                        Label("扫描网页上的二维码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    Text("二维码只用于发起加入请求；仍需在网页确认这台设备。").font(.footnote).foregroundStyle(.secondary)
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
