import UIKit
import Vision

struct TextRecognitionResult {
    let text: String
    let durationMs: Int
    let lineCount: Int
}

enum TextRecognizer {
    static func recognizeText(in image: UIImage) async -> TextRecognitionResult {
        guard let cgImage = image.cgImage else {
            return TextRecognitionResult(text: "", durationMs: 0, lineCount: 0)
        }

        let startedAt = Date()
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let strings = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.isEmpty } ?? []
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                continuation.resume(
                    returning: TextRecognitionResult(
                        text: strings.joined(separator: "\n"),
                        durationMs: durationMs,
                        lineCount: strings.count
                    )
                )
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                continuation.resume(
                    returning: TextRecognitionResult(text: "", durationMs: durationMs, lineCount: 0)
                )
            }
        }
    }
}
