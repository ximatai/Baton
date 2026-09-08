import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct BatonPhotoPicker: UIViewControllerRepresentable {
    let limit: Int
    let selected: @MainActor ([Data]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.selectionLimit = limit
        configuration.filter = .images
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: @MainActor ([Data]) -> Void
        init(selected: @escaping @MainActor ([Data]) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            Task {
                var data: [Data] = []
                for result in results {
                    guard result.itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
                    let value: Data? = await withCheckedContinuation { continuation in
                        result.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { value, _ in
                            continuation.resume(returning: value)
                        }
                    }
                    guard let value else { continue }
                    data.append(value)
                }
                await selected(data)
            }
        }
    }
}
