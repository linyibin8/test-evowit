import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit

final class LiveQuestionViewModel: NSObject, ObservableObject {
    @Published var permissionDenied = false
    @Published var statusText = "等待相机"
    @Published var hintText = "请将一道完整题目放进中间取景框，优先使用“拍照识别”获取单题结果。"
    @Published var currentText = ""
    @Published var currentCropImage: UIImage?
    @Published var currentIntent: LiveQuestionIntentInfo?
    @Published var ocrSummary = "等待检测到题目后输出 OCR 结果。"
    @Published var statusBadge = "准备中"
    @Published var detectedRect: CGRect?
    @Published var isRefreshing = false
    @Published var currentSource: QuestionResultSource?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "testevowit.camera.session")
    private let analysisQueue = DispatchQueue(label: "testevowit.camera.analysis")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let ciContext = CIContext(options: nil)
    private let profile = QuestionCaptureProfile.live

    private var isConfigured = false
    private var lastPreviewAnalysisAt: CFTimeInterval = 0
    private var lastDetectionAt: CFTimeInterval = 0
    private var pendingStableKey: String?
    private var pendingStableCount = 0
    private var stableBlockID: String?
    private var activeStableBlockID: String?
    private var inFlightDetailBlockID: String?
    private var lastDetailedBlockID: String?
    private var lastDetailedScanAt: CFTimeInterval = 0
    private var latestFrameImage: UIImage?
    private var manualResultLocked = false

    var previewFocusRect: CGRect {
        profile.focusRect
    }

    var resultSourceLabel: String {
        currentSource?.rawValue ?? "等待结果"
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionDenied = !granted
                    if granted {
                        self?.configureAndStartSession()
                    }
                }
            }
        default:
            permissionDenied = true
            statusText = "相机权限未开启"
            hintText = "请到 iPhone 设置中打开相机权限，或先从相册导入题目图片。"
            statusBadge = "权限受限"
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
        guard !permissionDenied else {
            statusText = "没有相机权限"
            hintText = "先开启相机权限，或使用相册导入。"
            statusBadge = "权限受限"
            return
        }

        beginManualAction(title: "正在拍照识别", hint: "请稳住手机 1 秒，系统会按单题重新裁切并做精识别。")

        sessionQueue.async {
            guard self.isConfigured else {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                    self.statusText = "相机还没准备好"
                    self.hintText = "请等待取景画面出现后再拍照识别。"
                    self.statusBadge = "等待相机"
                }
                return
            }

            let settings = AVCapturePhotoSettings()
            if let camera = (self.session.inputs.first as? AVCaptureDeviceInput)?.device,
               camera.hasFlash {
                settings.flashMode = .off
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func analyzeCurrentFrame() {
        guard let image = latestFrameImage else {
            statusText = "还没有可识别画面"
            hintText = "请先把题目对准镜头，等画面稳定后再点“识别当前画面”。"
            statusBadge = "等待画面"
            return
        }

        beginManualAction(title: "正在识别当前画面", hint: "系统会优先提取画面中的单题，并在必要时启用中心区域兜底裁切。")
        analyzeStillImage(image, source: .currentFrame, pinResult: true)
    }

    func importPhoto(_ image: UIImage) {
        beginManualAction(title: "正在识别相册图片", hint: "系统会从图片里找出最像单题的区域，再输出裁切后的题面。")
        analyzeStillImage(image, source: .photoLibrary, pinResult: true)
    }

    func reportImportFailure() {
        statusText = "相册导入失败"
        hintText = "这张图片暂时无法读取，换一张更清晰的题目图片再试。"
        statusBadge = "导入失败"
        isRefreshing = false
    }

    func resetRecognition() {
        manualResultLocked = false
        activeStableBlockID = nil
        currentSource = nil
        currentText = ""
        currentCropImage = nil
        currentIntent = nil
        detectedRect = nil
        isRefreshing = false
        statusText = session.isRunning ? "正在重新扫描题目" : "请对准一道题"
        hintText = "把一道完整题目放进框内，可以直接点“拍照识别”获得更稳的单题结果。"
        ocrSummary = "等待检测到题目后输出 OCR 结果。"
        statusBadge = "实时扫描中"

        analysisQueue.async {
            self.pendingStableKey = nil
            self.pendingStableCount = 0
            self.stableBlockID = nil
            self.inFlightDetailBlockID = nil
            self.lastDetailedBlockID = nil
            self.lastDetailedScanAt = 0
        }
    }

    private func beginManualAction(title: String, hint: String) {
        isRefreshing = true
        statusText = title
        hintText = hint
        statusBadge = "处理中"
    }

    private func configureAndStartSession() {
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
            }

            guard self.isConfigured else {
                DispatchQueue.main.async {
                    self.statusText = "相机启动失败"
                    self.hintText = "未能初始化后置摄像头，请检查设备和权限状态。"
                    self.statusBadge = "启动失败"
                }
                return
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                self.statusText = "请对准一道题"
                self.hintText = "实时识别会先跟踪题面，你也可以直接点“拍照识别”快速拿到单题结果。"
                self.statusBadge = "实时扫描中"
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

        if camera.isFocusModeSupported(.continuousAutoFocus) || camera.isExposureModeSupported(.continuousAutoExposure) {
            if (try? camera.lockForConfiguration()) != nil {
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }
                camera.unlockForConfiguration()
            }
        }

        guard session.canAddOutput(videoOutput) else {
            return
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        session.addOutput(videoOutput)

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        if let connection = photoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }

        isConfigured = true
    }

    private func stableBlock(from block: DetectedQuestionBlock?) -> DetectedQuestionBlock? {
        guard let block else {
            pendingStableKey = nil
            pendingStableCount = 0
            stableBlockID = nil
            return nil
        }

        let stableKey = [
            Int((block.normalizedRect.midX * 14).rounded()),
            Int((block.normalizedRect.midY * 14).rounded()),
            Int((block.normalizedRect.width * 14).rounded()),
            Int((block.normalizedRect.height * 14).rounded())
        ]
        .map(String.init)
        .joined(separator: ":")

        if stableBlockID == block.blockID {
            return block
        }

        if pendingStableKey == stableKey {
            pendingStableCount += 1
        } else {
            pendingStableKey = stableKey
            pendingStableCount = 1
        }

        guard pendingStableCount >= profile.stableFramesRequired else {
            return nil
        }

        pendingStableKey = nil
        pendingStableCount = 0
        stableBlockID = block.blockID
        return block
    }

    private func publishLiveCandidate(
        candidate: DetectedQuestionBlock?,
        stable: DetectedQuestionBlock?,
        frameImage: UIImage?
    ) {
        let now = CACurrentMediaTime()

        guard let candidate else {
            activeStableBlockID = nil

            if manualResultLocked {
                if now - lastDetectionAt > 1.2 {
                    detectedRect = nil
                }
                return
            }

            if now - lastDetectionAt > 0.9 {
                detectedRect = nil
                currentSource = nil
                currentText = ""
                currentCropImage = nil
                currentIntent = nil
                ocrSummary = "等待检测到题目后输出 OCR 结果。"
                statusText = "请将单题放进取景框"
                hintText = "一道题尽量铺满框内，不要把上一题和下一题一起拍进来。"
                statusBadge = "正在找题"
                isRefreshing = false
            }
            return
        }

        lastDetectionAt = now
        detectedRect = candidate.normalizedRect
        activeStableBlockID = stable?.blockID

        guard !manualResultLocked else {
            if !isRefreshing {
                statusText = "结果已固定"
                hintText = "点击“重新扫描”恢复实时识别，或继续拍照锁定下一题。"
                statusBadge = currentSource?.rawValue ?? "手动结果"
            }
            return
        }

        let source: QuestionResultSource = stable == nil ? .livePreview : .liveLocked
        currentSource = source
        currentText = candidate.previewText
        currentIntent = QuestionIntentRecognizer.recognize(text: candidate.previewText, lineCount: candidate.lineCount)
        currentCropImage = frameImage.flatMap {
            QuestionSegmentationEngine.cropQuestion(from: $0, normalizedRect: candidate.normalizedRect, padding: 0.05)
        }
        ocrSummary = "\(source.rawValue) | \(candidate.lineCount) 行 | 置信 \(Int((candidate.confidence * 100).rounded()))%"
        statusText = stable == nil ? "已跟踪到当前题目" : "当前题目已锁定"
        hintText = stable == nil
            ? "可以直接点“拍照识别”或“识别当前画面”，不要只等自动锁题。"
            : "题面已经稳定，系统会继续刷新更清晰的 OCR。"
        statusBadge = source.rawValue
    }

    private func maybeRunDetailedScan(with block: DetectedQuestionBlock, frameImage: UIImage, now: CFTimeInterval) {
        let shouldSkipBecauseRecent = block.blockID == lastDetailedBlockID
            && now - lastDetailedScanAt < profile.accurateRefreshInterval

        guard inFlightDetailBlockID == nil, !shouldSkipBecauseRecent else {
            return
        }

        inFlightDetailBlockID = block.blockID
        DispatchQueue.main.async {
            if !self.manualResultLocked {
                self.isRefreshing = true
                self.statusBadge = "正在精识别"
            }
        }

        Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            let analysis = QuestionSegmentationEngine.analyzeStillImage(
                frameImage,
                focusRect: self.profile.focusRect,
                source: .liveLocked
            )

            await MainActor.run {
                guard self.activeStableBlockID == block.blockID, !self.manualResultLocked else {
                    self.isRefreshing = false
                    return
                }

                self.applySnapshot(
                    analysis.snapshot,
                    detectedRect: analysis.detectedRect ?? block.normalizedRect,
                    statusText: "当前题目已锁定",
                    hintText: analysis.usedFallbackCrop
                        ? "已启用中心区域兜底裁切。你也可以点“拍照识别”获取更稳的单题结果。"
                        : "题面锁定成功，继续保持画面稳定会自动刷新 OCR。",
                    pinResult: false
                )
            }

            self.analysisQueue.async { [weak self] in
                self?.inFlightDetailBlockID = nil
                self?.lastDetailedBlockID = block.blockID
                self?.lastDetailedScanAt = CACurrentMediaTime()
            }
        }
    }

    private func analyzeStillImage(_ image: UIImage, source: QuestionResultSource, pinResult: Bool) {
        Task(priority: .userInitiated) { [weak self] in
            guard let self else {
                return
            }

            let analysis = QuestionSegmentationEngine.analyzeStillImage(
                image,
                focusRect: self.profile.focusRect,
                source: source
            )

            await MainActor.run {
                let statusText: String
                if analysis.snapshot.text.isEmpty {
                    statusText = "\(source.rawValue)未识别到清晰题目"
                } else {
                    statusText = "\(source.rawValue)已完成"
                }

                let hintText: String
                if analysis.snapshot.text.isEmpty {
                    hintText = "请让题目更近一点、光线更亮一点，或换一张更完整的题目图片再试。"
                } else if analysis.usedFallbackCrop {
                    hintText = pinResult
                        ? "结果已固定，且启用了中心区域兜底裁切。点击“重新扫描”可回到实时识别。"
                        : "识别时启用了兜底裁切，建议靠近后再拍一张会更稳。"
                } else {
                    hintText = pinResult
                        ? "结果已固定。点击“重新扫描”可回到实时识别。"
                        : "继续保持题面稳定，系统会自动刷新结果。"
                }

                self.applySnapshot(
                    analysis.snapshot,
                    detectedRect: analysis.detectedRect,
                    statusText: statusText,
                    hintText: hintText,
                    pinResult: pinResult
                )
            }
        }
    }

    private func applySnapshot(
        _ snapshot: LiveQuestionSnapshot,
        detectedRect: CGRect?,
        statusText: String,
        hintText: String,
        pinResult: Bool
    ) {
        manualResultLocked = pinResult
        currentSource = snapshot.source
        currentText = snapshot.text
        currentCropImage = snapshot.cropImage
        currentIntent = snapshot.intent
        ocrSummary = snapshot.ocrSummary
        self.detectedRect = detectedRect
        self.statusText = statusText
        self.hintText = hintText
        statusBadge = snapshot.source.rawValue
        isRefreshing = false
    }

    private func makeFrameImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(CGImagePropertyOrientation.right.rawValue))

        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

extension LiveQuestionViewModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastPreviewAnalysisAt >= profile.previewInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        lastPreviewAnalysisAt = now

        let frameImage = makeFrameImage(from: pixelBuffer)
        let detected = QuestionSegmentationEngine.detectBestQuestion(
            in: pixelBuffer,
            orientation: .right,
            focusRect: profile.focusRect
        )
        let stable = stableBlock(from: detected)

        if let stable, let frameImage {
            maybeRunDetailedScan(with: stable, frameImage: frameImage, now: now)
        }

        DispatchQueue.main.async {
            self.latestFrameImage = frameImage
            self.publishLiveCandidate(candidate: detected, stable: stable, frameImage: frameImage)
        }
    }
}

extension LiveQuestionViewModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.statusText = "拍照失败"
                self.hintText = error.localizedDescription
                self.statusBadge = "拍照失败"
            }
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data)
        else {
            DispatchQueue.main.async {
                self.isRefreshing = false
                self.statusText = "拍照失败"
                self.hintText = "没有拿到可用的照片数据，请重新试一次。"
                self.statusBadge = "拍照失败"
            }
            return
        }

        analyzeStillImage(image, source: .photoCapture, pinResult: true)
    }
}
