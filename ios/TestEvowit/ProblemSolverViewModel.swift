import Foundation
import UIKit

@MainActor
final class ProblemSolverViewModel: ObservableObject {
    @Published var selectedSubject: ProblemSubject = .math
    @Published var answerStyle: AnswerStyle = .guided
    @Published var gradeBand: GradeBand = .middleSchool
    @Published var questionHint: String = ""
    @Published var recognizedText: String = ""
    @Published var selectedImage: UIImage?
    @Published var latestResult: SolveProblemResponse?
    @Published var history: [SolveHistoryItem] = []
    @Published var isSubmitting = false
    @Published var isRecognizing = false
    @Published var errorMessage: String?
    @Published var recognitionStatus: String = "请先拍一题，并尽量裁到单题。"
    @Published var recognitionHint: String = "拍照后会先在本地做 OCR，再决定是否交给大模型。"

    private let apiClient = APIClient()
    private let isoFormatter = ISO8601DateFormatter()
    private var sessionId: String?
    private var lastPickerSource: PickerSource?
    private var cropApplied = false
    private var recognitionResult = TextRecognitionResult(
        text: "",
        durationMs: 0,
        lineCount: 0,
        qualityLevel: .poor,
        qualityMessage: "请先拍一题，并尽量裁到单题。",
        preprocessProfile: "original"
    )

    func solve() async {
        guard let selectedImage else {
            errorMessage = "请先拍照或从相册中选择一道题。"
            return
        }

        if isRecognizing {
            errorMessage = "题干还在识别中，请稍等识别完成。"
            return
        }

        let trimmedHint = questionHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if recognitionResult.qualityLevel != .good && trimmedHint.isEmpty {
            errorMessage = recognitionResult.qualityMessage
            return
        }

        guard let jpegData = selectedImage.jpegData(compressionQuality: 0.82) else {
            errorMessage = "图片编码失败，请换一张更清晰的题目图。"
            return
        }

        isSubmitting = true
        errorMessage = nil

        let cgImage = selectedImage.cgImage
        let request = SolveProblemRequest(
            sessionId: sessionId,
            subject: selectedSubject.rawValue,
            gradeBand: gradeBand.rawValue,
            answerStyle: answerStyle.rawValue,
            questionHint: trimmedHint.isEmpty ? nil : trimmedHint,
            recognizedText: recognizedText.isEmpty ? nil : recognizedText,
            clientTrace: SolveClientTrace(
                source: lastPickerSource?.rawValue,
                recognizer: "vision.VNRecognizeTextRequest",
                preprocessProfile: recognitionResult.preprocessProfile,
                cropApplied: cropApplied,
                ocrQuality: recognitionResult.qualityLevel.rawValue,
                ocrQualityReason: recognitionResult.qualityMessage,
                ocrDurationMs: recognitionResult.durationMs,
                recognizedLineCount: recognitionResult.lineCount,
                recognizedTextLength: recognizedText.count,
                imageWidth: cgImage?.width,
                imageHeight: cgImage?.height,
                imageBytes: jpegData.count,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                clientStartedAt: isoFormatter.string(from: Date())
            )
        )

        do {
            let response = try await apiClient.solve(request, imageData: jpegData)
            latestResult = response
            sessionId = response.sessionId

            if let thumbnailData = selectedImage.jpegData(compressionQuality: 0.55) {
                history.insert(
                    SolveHistoryItem(
                        thumbnailData: thumbnailData,
                        problemText: response.cleanedQuestion,
                        answer: response.answer
                    ),
                    at: 0
                )
                history = Array(history.prefix(6))
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isSubmitting = false
    }

    func setImage(_ image: UIImage, source: PickerSource, cropApplied: Bool) {
        selectedImage = image
        latestResult = nil
        errorMessage = nil
        lastPickerSource = source
        self.cropApplied = cropApplied
        recognitionResult = TextRecognitionResult(
            text: "",
            durationMs: 0,
            lineCount: 0,
            qualityLevel: .poor,
            qualityMessage: "正在识别题干...",
            preprocessProfile: "original"
        )
        recognizedText = ""
        isRecognizing = true
        recognitionStatus = "正在本地识别题干..."
        recognitionHint = cropApplied ? "已裁题，正在优先识别单题内容。" : "建议把画面裁到单题后再提交，准确率会更高。"

        Task {
            let result = await TextRecognizer.recognizeText(in: image)
            await MainActor.run {
                self.recognitionResult = result
                self.recognizedText = result.text
                self.isRecognizing = false
                self.recognitionStatus = statusText(for: result.qualityLevel)
                self.recognitionHint = result.qualityMessage
            }
        }
    }

    func reset() {
        selectedImage = nil
        latestResult = nil
        questionHint = ""
        recognizedText = ""
        errorMessage = nil
        sessionId = nil
        lastPickerSource = nil
        cropApplied = false
        isRecognizing = false
        recognitionStatus = "请先拍一题，并尽量裁到单题。"
        recognitionHint = "拍照后会先在本地做 OCR，再决定是否交给大模型。"
        recognitionResult = TextRecognitionResult(
            text: "",
            durationMs: 0,
            lineCount: 0,
            qualityLevel: .poor,
            qualityMessage: recognitionHint,
            preprocessProfile: "original"
        )
    }

    private func statusText(for quality: OCRQualityLevel) -> String {
        switch quality {
        case .good:
            return "题干识别完成"
        case .needsCrop:
            return "建议先裁成单题"
        case .poor:
            return "识别质量偏低"
        }
    }
}
