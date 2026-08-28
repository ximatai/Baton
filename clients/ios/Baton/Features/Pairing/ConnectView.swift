import SwiftUI

struct ConnectView: View {
    @ObservedObject var model: BatonViewModel
    @State private var isShowingScanner = false
    @State private var isShowingAbout = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            if model.isWaitingForApproval {
                PairingWaitView(model: model)
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 80, height: 80)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                Text("扫码加入对话")
                    .font(.title2.weight(.semibold))
                Text("扫描网页上的 Baton 二维码")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button { isShowingScanner = true } label: {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.isBusy)
                if model.isBusy {
                    ProgressView(model.connectionStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #if DEBUG && targetEnvironment(simulator)
                Button("连接本地演示服务") { model.connectLocalDemo() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                #endif
            }
            if let error = model.errorMessage {
                ErrorNotice(text: error, retry: model.retryLastConnection)
            }
            Spacer()
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $isShowingScanner) {
            QRScannerSheet { pairingURL in
                model.connect(pairingURL: pairingURL)
            }
        }
        .sheet(isPresented: $isShowingAbout) {
            BatonAboutSheet()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isShowingAbout = true } label: {
                    Image(systemName: "lightbulb")
                }
                .accessibilityLabel("关于 Baton")
            }
        }
    }
}
