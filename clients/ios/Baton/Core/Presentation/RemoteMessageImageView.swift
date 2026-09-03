import SwiftUI
import UIKit

/// Presentation-only view for a pre-validated MessageImage. It never opens a
/// URL itself: all image bytes come from BatonImageLoader in Core/Protocol.
struct RemoteMessageImageView: View {
    let content: MessageImage
    let loader: BatonImageLoader?
    let maximumHeight: CGFloat
    let openGallery: (() -> Void)?

    @State private var image: UIImage?
    @State private var failed = false
    @State private var isPreviewPresented = false
    @State private var retryID = 0

    /// A conversation can be popped and reopened with the same immutable
    /// `media_id` but a fresh, authenticated loader. Keep the task tied to
    /// that loader too: otherwise SwiftUI may retain a prior failed
    /// task state and never ask the new loader for its disk copy or network
    /// retry.
    private var loadRequestID: ImageLoadRequestID {
        ImageLoadRequestID(
            mediaID: content.mediaID,
            retryID: retryID,
            loaderID: loader.map(ObjectIdentifier.init)
        )
    }

    init(
        content: MessageImage,
        loader: BatonImageLoader?,
        maximumHeight: CGFloat = 220,
        openGallery: (() -> Void)? = nil
    ) {
        self.content = content
        self.loader = loader
        self.maximumHeight = maximumHeight
        self.openGallery = openGallery
    }

    var body: some View {
        Group {
            if let image {
                Button {
                    if let openGallery { openGallery() }
                    else { isPreviewPresented = true }
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: maximumHeight)
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
        .task(id: loadRequestID) {
            guard let loader else {
                image = nil
                failed = true
                return
            }
            image = nil
            failed = false
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
            MessageImageGallery(images: [content], loader: loader, initialMediaID: content.mediaID)
        }
    }
}

struct MessageImageGallery: View {
    let images: [MessageImage]
    let loader: BatonImageLoader?
    let initialMediaID: String
    @State private var selectedMediaID: String
    @Environment(\.dismiss) private var dismiss

    init(images: [MessageImage], loader: BatonImageLoader?, initialMediaID: String) {
        self.images = images
        self.loader = loader
        self.initialMediaID = initialMediaID
        _selectedMediaID = State(initialValue: initialMediaID)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedMediaID) {
                ForEach(images) { image in
                    ImagePreviewPage(content: image, loader: loader)
                        .tag(image.mediaID)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .background(.black)
            .navigationTitle(images.count > 1 ? "图片 \(pageNumber) / \(images.count)" : "图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var pageNumber: Int {
        (images.firstIndex(where: { $0.mediaID == selectedMediaID }) ?? 0) + 1
    }
}

private struct ImagePreviewPage: View {
    let content: MessageImage
    let loader: BatonImageLoader?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale = 1.0
    @State private var lastScale = 1.0

    private var loadRequestID: ImageLoadRequestID {
        ImageLoadRequestID(
            mediaID: content.mediaID,
            retryID: 0,
            loaderID: loader.map(ObjectIdentifier.init)
        )
    }

    var body: some View {
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
                    .accessibilityLabel(content.alt)
            } else if failed || loader == nil {
                Label("图片无法加载", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(content.alt)，图片无法加载")
            } else {
                ProgressView("正在加载图片…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .background(.black)
        .task(id: loadRequestID) {
            guard let loader else {
                image = nil
                failed = true
                return
            }
            image = nil
            failed = false
            do {
                image = try await loader.image(for: content)
                failed = false
            } catch {
                failed = true
            }
        }
    }
}

private struct ImageLoadRequestID: Hashable {
    let mediaID: String
    let retryID: Int
    let loaderID: ObjectIdentifier?
}
