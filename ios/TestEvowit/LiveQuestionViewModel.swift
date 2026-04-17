import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit

final class LiveQuestionViewModel: NSObject, ObservableObject {
    @Published var permissionDenied = false
    @Published var statusText = "等待相机"
    @Published var hintText = "请将一道完整题目放入中间取景框，系统会实时锁定当前单题。"
    @Published var currentText = ""
    @Published var currentCropImage: UIImage?
    @Published var currentIntent: LiveQuestionIntentInfo?
    @Published var ocrSummary = "等待锁定单题后再输出 OCR 结果。"
    @Published var statusBadge = "实时扫描中"
    @Published var detectedRect: CGRect?
    @Published var isRefreshing = false

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "testevowit.camera.session")
    private let analysisQueue = DispatchQueue(label: "testevowit.camera.analysis")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: nil)
    private let profile = QuestionCaptureProfile.live

    private var isConfigured = false
    private var lastPreviewAnalysisAt: CFTimeInterval = 0
    private var lastDetectionAt: CFTimeInterval = 0
    private var pendingStableKey: String?
    private var pendingStableCount = 0
    private var stableBlockID: String?
    private var inFlightDetailBlockID: String?
    private var lastDetailedBlockID: String?
    private var lastDetailedScanAt: CFTimeInterval = 0

    var previewFocusRect: CGRect {
        profile.focusRect
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
            hintText = "请到 iPhone 设置中开启相机权限后再返回此页面。"
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

            guard self.isConfigured else {
                DispatchQueue.main.async {
                    self.statusText = "相机启动失败"
                    self.hintText = "未能初始化后置摄像头，请检查设备和权限状态。"
                }
                return
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            DispatchQueue.main.async {
                self.statusText = "请对准一道题"
                self.statusBadge = "实时扫描中"
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

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
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

    private func publish(block: DetectedQuestionBlock?) {
        let now = CACurrentMediaTime()

        guard let block else {
            if now - lastDetectionAt > 0.9 {
                detectedRect = nil
                currentText = ""
                currentCropImage = nil
                currentIntent = nil
                ocrSummary = "等待锁定单题后再输出 OCR 结果。"
                statusText = "请将单题放进取景框"
                hintText = "不要把上一题或下一题一起拍进来，画面越干净越容易锁定。"
                statusBadge = "正在找题"
                isRefreshing = false
            }
            return
        }

        lastDetectionAt = now
        detectedRect = block.normalizedRect
        statusText = "已锁定当前题目"
        hintText = "保持当前题目在框内，文字和切图会持续刷新。"
        statusBadge = isRefreshing ? "正在刷新 OCR" : "单题已锁定"

        if currentText.isEmpty || currentIntent == nil || stableBlockID == block.blockID {
            currentText = block.previewText
            currentIntent = QuestionIntentRecognizer.recognize(text: block.previewText, lineCount: block.lineCount)
            ocrSummary = "预览 OCR | \(block.lineCount) 行 | 置信 \(Int((block.confidence * 100).rounded()))%"
        }
    }

    private func maybeRunDetailedScan(with block: DetectedQuestionBlock, pixelBuffer: CVPixelBuffer, now: CFTimeInterval) {
        let shouldSkipBecauseRecent = block.blockID == lastDetailedBlockID
            && now - lastDetailedScanAt < profile.accurateRefreshInterval

        guard inFlightDetailBlockID == nil,
              !shouldSkipBecauseRecent,
              let frameImage = makeFrameImage(from: pixelBuffer)
        else {
            return
        }

        inFlightDetailBlockID = block.blockID
        DispatchQueue.main.async {
            self.isRefreshing = true
            self.statusBadge = "正在刷新 OCR"
        }

        Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            let crop = QuestionSegmentationEngine.cropQuestion(
                from: frameImage,
                normalizedRect: block.normalizedRect,
                padding: 0.08
            )
            let ocr = crop.map { QuestionOCRService.recognizeQuestion(in: $0) }
            let finalText = Self.normalize(ocr?.text ?? block.previewText)
            let intent = QuestionIntentRecognizer.recognize(
                text: finalText.isEmpty ? block.previewText : finalText,
                lineCount: ocr?.lineCount ?? block.lineCount
            )
            let summary = makeOCRSummary(ocr: ocr, fallbackBlock: block)
            let snapshot = LiveQuestionSnapshot(
                text: finalText.isEmpty ? block.previewText : finalText,
                cropImage: crop,
                intent: intent,
                ocrSummary: summary
            )

            await MainActor.run {
                guard self.stableBlockID == block.blockID else {
                    self.isRefreshing = false
                    return
                }

                self.currentText = snapshot.text
                self.currentCropImage = snapshot.cropImage
                self.currentIntent = snapshot.intent
                self.ocrSummary = snapshot.ocrSummary
                self.isRefreshing = false
                self.statusBadge = "单题已锁定"
                self.statusText = "当前题目已更新"
                self.hintText = "移动到下一题时，系统会自动切换并重新裁切单题。"
            }

            self.analysisQueue.async { [weak self] in
                self?.inFlightDetailBlockID = nil
                self?.lastDetailedBlockID = block.blockID
                self?.lastDetailedScanAt = CACurrentMediaTime()
            }
        }
    }

    private func makeOCRSummary(ocr: QuestionOCRResult?, fallbackBlock: DetectedQuestionBlock) -> String {
        guard let ocr else {
            return "预览 OCR | \(fallbackBlock.lineCount) 行 | 取景稳定中"
        }

        return "高精度 OCR | \(ocr.quality.rawValue) | \(ocr.lineCount) 行 | \(ocr.preprocessProfile)"
    }

    private func makeFrameImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(CGImagePropertyOrientation.right.rawValue))

        guard let cgImage = ciContext.createCGImage(oriented, from: oriented.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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

        let detected = QuestionSegmentationEngine.detectBestQuestion(
            in: pixelBuffer,
            orientation: .right,
            focusRect: profile.focusRect
        )
        let stable = stableBlock(from: detected)

        if let stable {
            maybeRunDetailedScan(with: stable, pixelBuffer: pixelBuffer, now: now)
        }

        DispatchQueue.main.async {
            self.publish(block: stable)
        }
    }
}
