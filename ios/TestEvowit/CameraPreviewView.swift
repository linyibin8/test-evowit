import AVFoundation
import SwiftUI
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let detectedRect: CGRect?
    let fallbackRect: CGRect

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.attach(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewContainerView, context: Context) {
        uiView.detectedRect = detectedRect
        uiView.fallbackRect = fallbackRect
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
    }

    private func updateOverlay() {
        guard bounds.width > 0, bounds.height > 0 else {
            return
        }

        let normalized = detectedRect ?? fallbackRect
        let metadataRect = CGRect(
            x: normalized.minX,
            y: 1 - normalized.maxY,
            width: normalized.width,
            height: normalized.height
        )
        let frameRect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        let roundedPath = UIBezierPath(roundedRect: frameRect, cornerRadius: 24)

        let maskPath = UIBezierPath(rect: bounds)
        maskPath.append(roundedPath)

        maskLayer.path = maskPath.cgPath
        focusLayer.path = roundedPath.cgPath
        focusLayer.strokeColor = (detectedRect == nil ? UIColor.white : UIColor.systemGreen).cgColor
    }
}
