import AVFoundation
import CoreImage
import ImageIO
import SwiftUI

struct QuestionCameraView: View {
    let onCapture: (UIImage, QuestionCaptureMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
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
            viewModel.captureHandler = { image, metadata in
                onCapture(image, metadata)
                dismiss()
            }
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            HStack {
                Button("Close") {
                    dismiss()
                }
                .foregroundStyle(.white)

                Spacer()

                Text("Auto Question Camera")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Color.clear
                    .frame(width: 44, height: 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Keep one question inside the center frame. The app locks only when that frame looks like a single question.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)

                Text(viewModel.guidanceText)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.78), Color.black.opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var preview: some View {
        ZStack(alignment: .bottom) {
            QuestionCameraPreview(session: viewModel.session, detectedRect: viewModel.detectedRect)
                .overlay(alignment: .topLeading) {
                    if viewModel.isCapturing {
                        ProgressView("Cropping and solving...")
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(20)
                    } else if viewModel.detectedRect != nil {
                        statusBadge(viewModel.lockBadgeText)
                            .padding(20)
                    } else {
                        statusBadge("Searching for a single question")
                            .padding(20)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            Text("If the frame looks right, tap once. The app will run one more strong crop check, then upload automatically.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.78))

            Button {
                viewModel.capturePhoto()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 78, height: 78)

                    Circle()
                        .stroke(Color.black.opacity(0.12), lineWidth: 4)
                        .frame(width: 66, height: 66)
                }
            }
            .disabled(viewModel.isCapturing || !viewModel.isSessionReady || viewModel.detectedRect == nil)

            Text(viewModel.detectedRect == nil ? "Wait for the green frame before capturing." : "Ready to capture.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.12), Color.black.opacity(0.82)],
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

            Text("Camera access is required.")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("Enable camera permission in iPhone Settings, then reopen the capture screen.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.82))

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
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

struct QuestionCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let detectedRect: CGRect?

    func makeUIView(context: Context) -> CameraPreviewContainerView {
        let view = CameraPreviewContainerView()
        view.attachSession(session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewContainerView, context: Context) {
        uiView.detectedRect = detectedRect
    }
}

final class CameraPreviewContainerView: UIView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let maskLayer = CAShapeLayer()
    private let frameLayer = CAShapeLayer()

    var detectedRect: CGRect? {
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

        let normalized = detectedRect ?? QuestionDetector.suggestedFocusRect
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

final class QuestionCameraViewModel: NSObject, ObservableObject {
    @Published var detectedRect: CGRect?
    @Published var guidanceText = "Point the camera at one question. A stronger detector will refine the frame automatically."
    @Published var isCapturing = false
    @Published var isSessionReady = false
    @Published var permissionDenied = false
    @Published var lockBadgeText = "Searching"

    let session = AVCaptureSession()

    var captureHandler: ((UIImage, QuestionCaptureMetadata) -> Void)?

    private let sessionQueue = DispatchQueue(label: "testevowit.camera.session")
    private let analysisQueue = DispatchQueue(label: "testevowit.camera.analysis")
    private let processingQueue = DispatchQueue(label: "testevowit.camera.processing")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: nil)

    private var isConfigured = false
    private var latestDetection: QuestionDetection?
    private var localDetection: QuestionDetection?
    private var remoteDetection: QuestionDetection?
    private var lastLocalCandidate: QuestionDetection?
    private var localCandidateStreak = 0
    private var lastAnalysisTime: CFTimeInterval = 0
    private var lastPositiveDetectionTime: CFTimeInterval = 0
    private var lastServerRequestTime: CFTimeInterval = 0
    private var lastServerResponseTime: CFTimeInterval = 0
    private var serverDetectionInFlight = false

    private var previewFocusRect: CGRect {
        QuestionDetector.suggestedFocusRect
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

    func capturePhoto() {
        guard !isCapturing else {
            return
        }

        guard latestDetection != nil else {
            guidanceText = "Wait for the green question frame, then tap capture."
            return
        }

        isCapturing = true
        guidanceText = "Running a final crop check and starting solve..."

        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        settings.isHighResolutionPhotoEnabled = true

        sessionQueue.async {
            self.photoOutput.capturePhoto(with: settings, delegate: self)
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
            }
        }
    }

    private func configureSession() {
        guard !isConfigured else {
            return
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

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

        guard session.canAddOutput(photoOutput),
              session.canAddOutput(videoOutput)
        else {
            return
        }

        session.addOutput(photoOutput)
        session.addOutput(videoOutput)

        photoOutput.maxPhotoQualityPrioritization = .quality

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)

        photoOutput.connection(with: .video)?.videoOrientation = .portrait
        videoOutput.connection(with: .video)?.videoOrientation = .portrait

        isConfigured = true
    }

    @MainActor
    private func applyLocalDetection(_ detection: QuestionDetection?) {
        localDetection = stabilizedLocalDetection(from: detection)
        refreshDisplayedDetection()
    }

    @MainActor
    private func applyServerDetection(_ detection: QuestionDetection?) {
        remoteDetection = detection
        lastServerResponseTime = CACurrentMediaTime()
        refreshDisplayedDetection()
    }

    @MainActor
    private func refreshDisplayedDetection() {
        let now = CACurrentMediaTime()
        let preferred = preferredDetection(now: now)

        if let preferred {
            lastPositiveDetectionTime = now
            latestDetection = preferred
            detectedRect = previewFocusRect

            if preferred.source == .serverFocusedLayout || preferred.source == .serverLayout {
                lockBadgeText = "Single question locked"
                guidanceText = "The strong detector confirmed one question inside the guide. If it looks right, tap capture."
            } else if preferred.source == .localGuideVision {
                lockBadgeText = "Guide locked"
                guidanceText = "The preview detector found one question inside the guide. Hold steady for a final cloud check."
            } else if remoteDetection == nil {
                lockBadgeText = "Preview lock"
                guidanceText = "The guide looks usable. Hold steady while the stronger detector confirms it."
            } else {
                lockBadgeText = "Refining"
                guidanceText = "Keep the same framing. The stronger detector is checking the guide area."
            }
        } else if localCandidateStreak > 0 {
            detectedRect = nil
            lockBadgeText = "Stabilizing"
            guidanceText = "Hold the phone steady. The guide needs one more clean frame before it locks."
        } else if now - lastPositiveDetectionTime > 0.9 {
            latestDetection = nil
            detectedRect = nil
            lockBadgeText = "Searching"
            guidanceText = "Move closer and keep just one question inside the center frame."
        }
    }

    @MainActor
    private func preferredDetection(now: CFTimeInterval) -> QuestionDetection? {
        if let remoteDetection, now - lastServerResponseTime <= 2.4 {
            return remoteDetection
        }
        return localDetection
    }

    private func maybeScheduleServerDetection(from pixelBuffer: CVPixelBuffer, localDetection: QuestionDetection?) {
        let now = CACurrentMediaTime()
        let hasRecentRemote = now - lastServerResponseTime < 1.8

        guard !serverDetectionInFlight,
              now - lastServerRequestTime >= 0.9,
              localDetection != nil || !hasRecentRemote,
              let jpegData = makePreviewJPEGData(from: pixelBuffer)
        else {
            return
        }

        serverDetectionInFlight = true
        lastServerRequestTime = now

        Task(priority: .utility) {
            let detection: QuestionDetection?
            do {
                let response = try await APIClient().detectQuestion(
                    in: jpegData,
                    focusRect: QuestionDetector.toServerRect(self.previewFocusRect)
                )
                detection = QuestionDetector.detectQuestion(from: response)
            } catch {
                detection = nil
            }

            await MainActor.run {
                self.serverDetectionInFlight = false
                self.applyServerDetection(detection)
            }
        }
    }

    private func makePreviewJPEGData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(CGImagePropertyOrientation.right.rawValue))
        let extent = oriented.extent.integral
        let longest = max(extent.width, extent.height)
        let scale = longest > 0 ? min(1, 1280 / longest) : 1
        let resized = scale < 1
            ? oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : oriented

        guard let cgImage = ciContext.createCGImage(resized, from: resized.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.62)
    }

    private func detectQuestionViaServer(
        in image: UIImage,
        focusRect: ServerNormalizedRect?
    ) async -> QuestionDetection? {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return nil
        }

        do {
            let response = try await APIClient().detectQuestion(in: imageData, focusRect: focusRect)
            return QuestionDetector.detectQuestion(from: response)
        } catch {
            return nil
        }
    }

    @MainActor
    private func stabilizedLocalDetection(from detection: QuestionDetection?) -> QuestionDetection? {
        guard let detection else {
            lastLocalCandidate = nil
            localCandidateStreak = 0
            return nil
        }

        if let previous = lastLocalCandidate,
           isSimilar(previous.normalizedRect, detection.normalizedRect) {
            localCandidateStreak += 1
        } else {
            localCandidateStreak = 1
        }

        lastLocalCandidate = detection
        return localCandidateStreak >= 2 ? detection : nil
    }

    private func isSimilar(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midX - rhs.midX) <= 0.08
            && abs(lhs.midY - rhs.midY) <= 0.08
            && abs(lhs.width - rhs.width) <= 0.12
            && abs(lhs.height - rhs.height) <= 0.12
    }
}

extension QuestionCameraViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isCapturing else {
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastAnalysisTime >= 0.25 else {
            return
        }
        lastAnalysisTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let rawDetection = QuestionDetector.detectQuestion(
            in: pixelBuffer,
            orientation: .right,
            focusRect: previewFocusRect,
            recognitionLevel: .fast
        )
        let detection = rawDetection?.source == .localGuideVision ? rawDetection : nil

        maybeScheduleServerDetection(from: pixelBuffer, localDetection: detection)

        DispatchQueue.main.async {
            self.applyLocalDetection(detection)
        }
    }
}

extension QuestionCameraViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.guidanceText = "Capture failed. Try again."
            }
            return
        }

        let previewDetection = latestDetection
        let originalWidth = image.cgImage?.width
        let originalHeight = image.cgImage?.height

        processingQueue.async {
            let focusRect = QuestionDetector.toServerRect(self.previewFocusRect)
            let focusedLocalResult = QuestionDetector.detectQuestion(
                in: image,
                focusRect: self.previewFocusRect,
                recognitionLevel: .accurate
            )
            let focusedLocal = focusedLocalResult?.source == .localGuideVision ? focusedLocalResult : nil

            Task(priority: .userInitiated) {
                let strongDetection = await self.detectQuestionViaServer(in: image, focusRect: focusRect)
                let chosen = strongDetection ?? focusedLocal ?? previewDetection
                let cropped = chosen.flatMap {
                    QuestionDetector.cropQuestion(from: image, using: $0)
                } ?? QuestionDetector.cropQuestion(
                    from: image,
                    normalizedRect: self.previewFocusRect,
                    padding: 0.04
                ) ?? image

                var warnings: [String] = []
                if strongDetection == nil {
                    warnings.append("server_final_detection_unavailable")
                }
                if chosen?.source == .localVision {
                    warnings.append("crop_from_local_detector")
                }
                if chosen?.source == .localGuideVision {
                    warnings.append("crop_from_local_focus_detector")
                }
                if chosen == nil {
                    warnings.append("fell_back_to_guide_frame_crop")
                }

                let metadata = QuestionCaptureMetadata(
                    cropApplied: true,
                    cropSource: chosen?.source ?? .guideFrame,
                    cropCoverage: chosen?.coverage ?? Double(self.previewFocusRect.width * self.previewFocusRect.height),
                    focusRect: focusRect,
                    originalImageWidth: originalWidth,
                    originalImageHeight: originalHeight,
                    previewDetectionSource: previewDetection?.source,
                    warnings: warnings
                )

                await MainActor.run {
                    self.isCapturing = false
                    self.captureHandler?(cropped, metadata)
                }
            }
        }
    }
}
