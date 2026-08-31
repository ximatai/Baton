import SwiftUI
import UIKit

/// Presentation-only view for a pre-validated MessageImage. It never opens a
/// URL itself: all image bytes come from BatonImageLoader in Core/Protocol.
struct RemoteMessageImageView: View {
    let content: MessageImage
    let loader: BatonImageLoader?

    @State private var image: UIImage?
    @State private var failed = false
    @State private var isPreviewPresented = false
    @State private var retryID = 0

    var body: some View {
        Group {
            if let image {
                Button { isPreviewPresented = true } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(content.alt)
                .accessibilityHint("点按全屏查看图片")
            } else if failed || loader == nil {
                HStack { Label("图片无法加载", systemImage: "photo.badge.exclamationmark"); if loader != nil { Button("重试") { failed = false; retryID += 1 } } }
                    .font(.footnote).foregroundStyle(.secondary).accessibilityLabel("\(content.alt)，图片无法加载")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在加载图片…").font(.footnote)
                }
                .foregroundStyle(.secondary)
                .frame(width: 180, height: 100)
                .accessibilityLabel("正在加载：\(content.alt)")
            }
        }
        .task(id: "\(content.url.absoluteString)#\(retryID)") {
            guard let loader else { return }
            do {
                image = try await loader.image(for: content)
                failed = false
            } catch {
                // The loader deliberately exposes no URL, credential, or bytes
                // through errors. The UI only presents a safe local fallback.
                failed = true
            }
        }
        .sheet(isPresented: $isPreviewPresented) {
            ImagePreview(image: image, alt: content.alt)
        }
    }
}

private struct ImagePreview: View {
    let image: UIImage?
    let alt: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var lastScale = 1.0

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 5) }
                                .onEnded { _ in lastScale = scale }
                        )
                        .accessibilityLabel(alt)
                }
            }
            .background(.black)
            .navigationTitle("图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
