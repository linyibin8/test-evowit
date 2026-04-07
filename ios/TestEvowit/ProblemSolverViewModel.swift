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
    private var sessionId: String?

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

        let request = SolveProblemRequest(
            sessionId: sessionId,
            subject: selectedSubject.rawValue,
            gradeBand: gradeBand.rawValue,
            answerStyle: answerStyle.rawValue,
            questionHint: questionHint.isEmpty ? nil : questionHint,
            recognizedText: recognizedText.isEmpty ? nil : recognizedText,
            imageBase64: jpegData.base64EncodedString()
        )

        do {
            let response = try await apiClient.solve(request)
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

    func setImage(_ image: UIImage) {
        selectedImage = image
        errorMessage = nil
        Task {
            recognizedText = await TextRecognizer.recognizeText(in: image)
        }
    }

    func reset() {
        selectedImage = nil
        latestResult = nil
        questionHint = ""
        recognizedText = ""
        errorMessage = nil
        sessionId = nil
    }
}

