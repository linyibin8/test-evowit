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
    @Published var errorMessage: String?

    private let apiClient = APIClient()
    private let isoFormatter = ISO8601DateFormatter()
    private var sessionId: String?
    private var lastPickerSource: PickerSource?
    private var recognitionResult = TextRecognitionResult(text: "", durationMs: 0, lineCount: 0)

    func solve() async {
        guard let selectedImage else {
            errorMessage = "请先拍照或选择一张题目图片。"
            return
        }

        guard let jpegData = selectedImage.jpegData(compressionQuality: 0.82) else {
            errorMessage = "图片编码失败，请换一张图片再试。"
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
            questionHint: questionHint.isEmpty ? nil : questionHint,
            recognizedText: recognizedText.isEmpty ? nil : recognizedText,
            clientTrace: SolveClientTrace(
                source: lastPickerSource?.rawValue,
                recognizer: "vision.VNRecognizeTextRequest",
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

    func setImage(_ image: UIImage, source: PickerSource) {
        selectedImage = image
        latestResult = nil
        errorMessage = nil
        lastPickerSource = source
        recognitionResult = TextRecognitionResult(text: "", durationMs: 0, lineCount: 0)

        Task {
            let result = await TextRecognizer.recognizeText(in: image)
            recognitionResult = result
            recognizedText = result.text
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
        recognitionResult = TextRecognitionResult(text: "", durationMs: 0, lineCount: 0)
    }
}
