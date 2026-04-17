import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let detectedRect: CGRect?
    let fallbackRect: CGRect
    let imageSize: CGSize

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewContainerView, context: Context) {
        uiView.detectedRect = detectedRect
        uiView.fallbackRect = fallbackRect
        uiView.imageSize = imageSize
    }
}

final class CameraPreviewContainerView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let maskLayer = CAShapeLayer()
    private let focusLayer = CAShapeLayer()

    var detectedRect: CGRect? {
        didSet { updateOverlay() }
    }

    var fallbackRect: CGRect = QuestionCaptureProfile.live.focusRect {
        didSet { updateOverlay() }
    }

    var imageSize: CGSize = .zero {
        didSet { updateOverlay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)

        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.42).cgColor
        maskLayer.fillRule = .evenOdd
        layer.addSublayer(maskLayer)

        focusLayer.fillColor = UIColor.clear.cgColor
        focusLayer.strokeColor = UIColor.white.cgColor
        focusLayer.lineWidth = 3
        focusLayer.lineDashPattern = [10, 8]
        layer.addSublayer(focusLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updateOverlay()
    }

    func attach(session: AVCaptureSession) {
        if previewLayer.session !== session {
            previewLayer.session = session
        }
        syncPreviewRotation()
    }

    private func updateOverlay() {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        syncPreviewRotation()

        let normalized = detectedRect ?? fallbackRect
        let frameRect = rectOnPreview(for: normalized)
        let roundedPath = UIBezierPath(roundedRect: frameRect, cornerRadius: 24)

        let maskPath = UIBezierPath(rect: bounds)
        maskPath.append(roundedPath)

        maskLayer.path = maskPath.cgPath
        focusLayer.path = roundedPath.cgPath
        focusLayer.strokeColor = (detectedRect == nil ? UIColor.white : UIColor.systemGreen).cgColor
    }

    private func rectOnPreview(for normalizedRect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            let metadataRect = CGRect(
                x: normalizedRect.minX,
                y: 1 - normalizedRect.maxY,
                width: normalizedRect.width,
                height: normalizedRect.height
            )
            return previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        }

        let imageRect = CGRect(
            x: normalizedRect.minX * imageSize.width,
            y: (1 - normalizedRect.maxY) * imageSize.height,
            width: normalizedRect.width * imageSize.width,
            height: normalizedRect.height * imageSize.height
        )

        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let xOffset = (bounds.width - scaledSize.width) / 2
        let yOffset = (bounds.height - scaledSize.height) / 2

        return CGRect(
            x: imageRect.minX * scale + xOffset,
            y: imageRect.minY * scale + yOffset,
            width: imageRect.width * scale,
            height: imageRect.height * scale
        )
    }

    private func syncPreviewRotation() {
        guard let connection = previewLayer.connection else {
            return
        }

        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}
