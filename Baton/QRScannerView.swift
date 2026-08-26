import SwiftUI
@preconcurrency import AVFoundation

/// Parses only the transport-independent QR payload. HTTPS and same-origin
/// validation deliberately remain in `BatonAPIClient`, the single network trust
/// boundary for both pasted and scanned URLs.
enum BatonPairingURLParser {
    static func parse(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}

private enum QRScannerAvailability: Equatable {
    case available
    case unsupported
    case denied
    case restricted
    case notDetermined
}

private func scannerAvailability() -> QRScannerAvailability {
    #if targetEnvironment(simulator)
    return .unsupported
    #else
    guard AVCaptureDevice.default(for: .video) != nil else { return .unsupported }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: return .available
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    @unknown default: return .unsupported
    }
    #endif
}

/// A presentation boundary for camera permission and user guidance. It does not
/// know about pairings, tokens, or conversation state.
struct QRScannerSheet: View {
    let onPairingURL: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var availability = scannerAvailability()
    @State private var isRequestingPermission = false

    var body: some View {
        NavigationStack {
            Group {
                switch availability {
                case .available:
                    QRCodeScannerView { rawValue in
                        guard let url = BatonPairingURLParser.parse(rawValue) else { return }
                        dismiss()
                        onPairingURL(url.absoluteString)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding()
                    .overlay(alignment: .bottom) {
                        Text("将网页上的 Baton Pairing 二维码放入取景框")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 22)
                    }
                case .notDetermined:
                    permissionPrompt
                case .denied:
                    guidance(
                        title: "未获得相机权限",
                        message: "请在“设置 > Baton > 相机”中允许访问后重试；也可以返回后粘贴 Pairing URL。",
                        actionTitle: "打开设置",
                        action: openSettings
                    )
                case .restricted:
                    guidance(
                        title: "相机访问受限",
                        message: "此设备的相机访问被系统或屏幕使用时间限制。你仍可返回后粘贴 Pairing URL。"
                    )
                case .unsupported:
                    guidance(
                        title: "当前环境不能扫码",
                        message: "模拟器或无相机设备不能扫描二维码。请返回后粘贴 Pairing URL，或在真机上继续。"
                    )
                }
            }
            .navigationTitle("扫描二维码")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
            }
        }
        .task {
            guard availability == .notDetermined, !isRequestingPermission else { return }
            isRequestingPermission = true
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            availability = granted ? .available : scannerAvailability()
            isRequestingPermission = false
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder").font(.system(size: 42)).foregroundStyle(.tint)
            Text("需要相机权限").font(.title3.bold())
            Text("Baton 只使用相机读取网页展示的配对二维码。扫码不会自动授权加入会话。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if isRequestingPermission { ProgressView("正在请求权限…") }
        }
        .padding()
    }

    private func guidance(title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// UIKit owns the capture session lifecycle. The SwiftUI surface only receives a
/// raw scanned value, keeping AVFoundation outside `BatonViewModel`.
private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerController {
        let controller = QRCodeScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerController, context: Context) {
        uiViewController.onCode = onCode
    }

    static func dismantleUIViewController(_ uiViewController: QRCodeScannerController, coordinator: ()) {
        uiViewController.stopScanning()
    }
}

private final class QRCodeScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let sessionQueue = DispatchQueue(label: "net.ximatai.baton.qr-scanner")
    private var isConfigured = false
    private var hasDeliveredCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        previewLayer.session = captureSession
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        configureAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    func stopScanning() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      self.captureSession.canAddInput(input) else { return }
                self.captureSession.addInput(input)

                let output = AVCaptureMetadataOutput()
                guard self.captureSession.canAddOutput(output) else { return }
                self.captureSession.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.isConfigured = true
            }
            guard !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasDeliveredCode else { return }
            guard BatonPairingURLParser.parse(value) != nil else { return }
            self.hasDeliveredCode = true
            self.stopScanning()
            self.onCode?(value)
        }
    }
}
