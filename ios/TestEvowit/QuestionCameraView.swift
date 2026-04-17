import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit

struct QuestionCameraView: View {
    @StateObject private var viewModel = QuestionCameraViewModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.permissionDenied {
                permissionView
            } else {
                VStack(spacing: 0) {
                    header
                    preview
                    footer
                }
            }
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Live OCR")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Keep one question inside the center frame. The app continuously outputs the exact question the camera sees right now.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))

            HStack(spacing: 10) {
                infoChip(viewModel.statusText, accent: viewModel.detectedRect == nil ? .white : .green)
                infoChip("On-device Vision OCR", accent: .cyan)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.82), Color.black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            QuestionCameraPreview(
                session: viewModel.session,
                detectedRect: viewModel.detectedRect,
                fallbackRect: viewModel.previewFocusRect
            )
            .background(Color.black)

            if viewModel.isRecognizing {
                statusBadge("Refreshing current question")
                    .padding(20)
            } else if viewModel.detectedRect != nil {
                statusBadge("Current question locked")
                    .padding(20)
            } else {
                statusBadge("Searching for one question")
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Current Question")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                if viewModel.isRecognizing {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                }
            }

            ScrollView {
                Text(viewModel.currentQuestionText.isEmpty ? "No stable single question is locked yet. Keep only the question you want to read inside the frame and the text below will update live." : viewModel.currentQuestionText)
                    .font(.body)
                    .foregroundStyle(viewModel.currentQuestionText.isEmpty ? .white.opacity(0.72) : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 220)

            Text(viewModel.guidanceText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.18), Color.black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)

            Text("Camera Access Needed")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("Enable camera permission in iPhone Settings, then reopen this screen.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(28)
    }

    private func infoChip(_ title: String, accent: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    private func statusBadge(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.48), in: Capsule())
    }
}

final class QuestionCameraViewModel: NSObject, ObservableObject {
    @Published var detectedRect: CGRect?
    @Published var guidanceText = "Keep one complete question inside the center frame and avoid showing two questions at once."
    @Published var statusText = "Waiting for camera"
    @Published var currentQuestionText = ""
    @Published var isRecognizing = false
    @Published var isSessionReady = false
    @Published var permissionDenied = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "testevowit.live.camera.session")
    private let analysisQueue = DispatchQueue(label: "testevowit.live.camera.analysis")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: nil)
    private let focusRect = QuestionCaptureProfile.balanced.focusRect

    private var isConfigured = false
    private var lastAnalysisTime: CFTimeInterval = 0
    private var lastRecognitionRequestTime: CFTimeInterval = 0
    private var recognitionSignatureInFlight: String?
    private var lastCompletedRecognitionSignature: String?
    private var lastCompletedRecognitionTime: CFTimeInterval = 0

    private var activeQuestionSignature: String?
    private var activePreviewSignature: String?
    private var currentRecognitionSignature: String?
    private var lastDetectedTime: CFTimeInterval = 0

    var previewFocusRect: CGRect {
        focusRect
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.permissionDenied = !granted
                    if granted {
                        self.configureAndStartSession()
                    }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                self.isSessionReady = self.isConfigured
                self.statusText = self.isConfigured ? "Place a question inside the frame" : "Camera failed to start"
            }
        }
    }

    private func configureSession() {
        guard !isConfigured else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .high

        defer {
            session.commitConfiguration()
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else {
            return
        }

        session.addInput(input)

        guard session.canAddOutput(videoOutput) else {
            return
        }

        session.addOutput(videoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        videoOutput.connection(with: .video)?.videoOrientation = .portrait

        isConfigured = true
    }

    private func applyDetection(_ detection: QuestionDetection?, signature: String?, previewText: String) {
        let now = CACurrentMediaTime()

        guard let detection, let signature else {
            if now - lastDetectedTime > 0.8 {
                detectedRect = nil
                currentQuestionText = ""
                activeQuestionSignature = nil
                activePreviewSignature = nil
                currentRecognitionSignature = nil
                isRecognizing = false
                statusText = isSessionReady ? "Place one full question inside the frame" : "Waiting for camera"
                guidanceText = "Keep only the question you want to read visible, without the previous or next question entering the frame."
            }
            return
        }

        lastDetectedTime = now
        detectedRect = detection.normalizedRect
        activeQuestionSignature = signature
        statusText = isRecognizing ? "Question locked, refreshing OCR" : "Current question locked"
        guidanceText = "Keep this question inside the frame and the text below will stay synced with what the camera sees."

        if !previewText.isEmpty && (activePreviewSignature != signature || currentQuestionText.count < 8) {
            currentQuestionText = previewText
            activePreviewSignature = signature
        }
    }

    private func markRecognitionStarted(signature: String) {
        currentRecognitionSignature = signature
        isRecognizing = true
    }

    private func applyRecognitionResult(_ result: TextRecognitionResult?, signature: String, fallbackText: String) {
        if currentRecognitionSignature == signature {
            currentRecognitionSignature = nil
            isRecognizing = false
        }

        guard activeQuestionSignature == signature else {
            return
        }

        let refinedText = Self.normalizedQuestionText(result?.text ?? "")
        if !refinedText.isEmpty {
            currentQuestionText = refinedText
            activePreviewSignature = signature
            statusText = "Current question updated"
            guidanceText = "Move to the next question and the text below will switch with it."
        } else if currentQuestionText.isEmpty && !fallbackText.isEmpty {
            currentQuestionText = fallbackText
        }
    }

    private func maybeScheduleRecognition(
        from pixelBuffer: CVPixelBuffer,
        detection: QuestionDetection,
        signature: String,
        fallbackText: String,
        now: CFTimeInterval
    ) {
        let isSameAsLast = signature == lastCompletedRecognitionSignature
        let hasRecentSame = isSameAsLast && now - lastCompletedRecognitionTime < 1.1

        guard recognitionSignatureInFlight == nil,
              now - lastRecognitionRequestTime >= 0.45,
              !hasRecentSame,
              let image = makeOrientedImage(from: pixelBuffer)
        else {
            return
        }

        recognitionSignatureInFlight = signature
        lastRecognitionRequestTime = now

        DispatchQueue.main.async {
            self.markRecognitionStarted(signature: signature)
        }

        Task(priority: .utility) {
            let cropped = QuestionDetector.cropQuestion(from: image, using: detection)
                ?? QuestionDetector.cropQuestion(
                    from: image,
                    normalizedRect: self.focusRect,
                    padding: 0.03
                )
            let result: TextRecognitionResult?
            if let cropped {
                result = await TextRecognizer.recognizeText(in: cropped)
            } else {
                result = nil
            }

            await MainActor.run {
                self.applyRecognitionResult(result, signature: signature, fallbackText: fallbackText)
            }

            self.analysisQueue.async {
                if self.recognitionSignatureInFlight == signature {
                    self.recognitionSignatureInFlight = nil
                }
                self.lastCompletedRecognitionSignature = signature
                self.lastCompletedRecognitionTime = CACurrentMediaTime()
            }
        }
    }

    private func makeOrientedImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(CGImagePropertyOrientation.right.rawValue))

        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private static func normalizedQuestionText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func questionSignature(for detection: QuestionDetection) -> String {
        let rect = detection.normalizedRect
        let rectKey = [
            Int((rect.midX * 18).rounded()),
            Int((rect.midY * 18).rounded()),
            Int((rect.width * 18).rounded()),
            Int((rect.height * 18).rounded())
        ]
        .map(String.init)
        .joined(separator: ":")

        let textKey = String(normalizedQuestionText(detection.recognizedText).prefix(24))
        return "\(rectKey)|\(textKey)"
    }
}

extension QuestionCameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= 0.24 else {
            return
        }
        lastAnalysisTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let rawDetection = QuestionDetector.detectQuestion(
            in: pixelBuffer,
            orientation: .right,
            focusRect: focusRect,
            recognitionLevel: .fast
        )
        let detection = rawDetection?.source == .localGuideVision ? rawDetection : nil
        let previewText = Self.normalizedQuestionText(detection?.recognizedText ?? "")
        let signature = detection.map(Self.questionSignature(for:))

        if let detection, let signature {
            maybeScheduleRecognition(
                from: pixelBuffer,
                detection: detection,
                signature: signature,
                fallbackText: previewText,
                now: now
            )
        }

        DispatchQueue.main.async {
            self.applyDetection(detection, signature: signature, previewText: previewText)
        }
    }
}

struct QuestionCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let detectedRect: CGRect?
    let fallbackRect: CGRect

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.attachSession(session)
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
    private let frameLayer = CAShapeLayer()

    var detectedRect: CGRect? {
        didSet { updateOverlay() }
    }

    var fallbackRect: CGRect = QuestionCaptureProfile.balanced.focusRect {
        didSet { updateOverlay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)

        maskLayer.fillColor = UIColor.black.withAlphaComponent(0.42).cgColor
        maskLayer.fillRule = .evenOdd
        layer.addSublayer(maskLayer)

        frameLayer.fillColor = UIColor.clear.cgColor
        frameLayer.strokeColor = UIColor.white.cgColor
        frameLayer.lineWidth = 3
        frameLayer.lineDashPattern = [10, 8]
        layer.addSublayer(frameLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        updateOverlay()
    }

    func attachSession(_ session: AVCaptureSession) {
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
        let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        let rounded = UIBezierPath(roundedRect: rect, cornerRadius: 24)

        let maskPath = UIBezierPath(rect: bounds)
        maskPath.append(rounded)

        maskLayer.path = maskPath.cgPath
        frameLayer.path = rounded.cgPath
        frameLayer.strokeColor = (detectedRect == nil ? UIColor.white : UIColor.systemGreen).cgColor
    }
}
