import UIKit
import Vision

enum TextRecognizer {
    static func recognizeText(in image: UIImage) async -> String {
        guard let cgImage = image.cgImage else {
            return ""
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let strings = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.isEmpty } ?? []
                continuation.resume(returning: strings.joined(separator: "\n"))
            }
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
