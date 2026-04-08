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
    let onImagePicked: (UIImage, PickerSource, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(source: source, onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(source.sourceType) ? source.sourceType : .photoLibrary
        controller.delegate = context.coordinator
        controller.allowsEditing = true
        controller.modalPresentationStyle = .fullScreen
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let source: PickerSource
        let onImagePicked: (UIImage, PickerSource, Bool) -> Void

        init(source: PickerSource, onImagePicked: @escaping (UIImage, PickerSource, Bool) -> Void) {
            self.source = source
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let editedImage = info[.editedImage] as? UIImage
            let originalImage = info[.originalImage] as? UIImage

            if let image = editedImage ?? originalImage {
                onImagePicked(image, source, editedImage != nil)
            }

            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
