import SwiftUI
import UIKit

enum PickerSource: String, Identifiable {
    case camera
    case photoLibrary

    var id: String { rawValue }

    var sourceType: UIImagePickerController.SourceType {
        switch self {
        case .camera: return .camera
        case .photoLibrary: return .photoLibrary
        }
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    let source: PickerSource
    let onImagePicked: (UIImage, PickerSource) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(source: source, onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(source.sourceType) ? source.sourceType : .photoLibrary
        controller.delegate = context.coordinator
        controller.allowsEditing = false
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let source: PickerSource
        let onImagePicked: (UIImage, PickerSource) -> Void

        init(source: PickerSource, onImagePicked: @escaping (UIImage, PickerSource) -> Void) {
            self.source = source
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePicked(image, source)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
