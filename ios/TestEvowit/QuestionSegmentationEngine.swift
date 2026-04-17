import CoreGraphics
import ImageIO
import UIKit
import Vision

enum QuestionSegmentationEngine {
    static func detectBestQuestion(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        focusRect: CGRect
    ) -> DetectedQuestionBlock? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let lines = recognizeLines(with: handler, recognitionLevel: .fast)
        return bestQuestion(from: lines, focusRect: focusRect, mode: .livePreview)
    }

    static func detectBestQuestion(in image: UIImage, focusRect: CGRect) -> DetectedQuestionBlock? {
        let normalizedImage = normalized(image)
        let lines = recognizeLines(in: normalizedImage, recognitionLevel: .accurate)
        return bestQuestion(from: lines, focusRect: focusRect, mode: .stillCapture)
    }

    static func analyzeStillImage(
        _ image: UIImage,
        focusRect: CGRect,
        source: QuestionResultSource
    ) -> StillImageQuestionAnalysis {
        let normalizedImage = normalized(image)
        let lines = recognizeLines(in: normalizedImage, recognitionLevel: .accurate)
        let rankedCandidates = rankedCandidates(from: lines, focusRect: focusRect, mode: .stillCapture)
        let evaluatedCandidates = rankedCandidates.prefix(4).compactMap {
            evaluateStillCandidate($0, image: normalizedImage)
        }

        let fallbackRect = preferredFallbackRect(from: focusRect)
        let fallbackCrop = cropQuestion(from: normalizedImage, normalizedRect: fallbackRect, padding: 0.03)
        let fallbackOCR = fallbackCrop.map { QuestionOCRService.recognizeQuestion(in: $0) }
        let bestCandidate = evaluatedCandidates.max(by: { $0.totalScore < $1.totalScore })

        let shouldUseFallback: Bool
        if let bestCandidate {
            let aspectRatio = bestCandidate.block.normalizedRect.width / max(bestCandidate.block.normalizedRect.height, 0.001)
            let looksTooVertical = aspectRatio < 0.78
            let scoreTooWeak = bestCandidate.totalScore < 58
            let fallbackPreferred = shouldPrefer(fallbackOCR, over: bestCandidate.ocr)
            shouldUseFallback = looksTooVertical || scoreTooWeak || fallbackPreferred
        } else {
            shouldUseFallback = true
        }

        let selectedRect = shouldUseFallback ? nil : bestCandidate?.block.normalizedRect
        let selectedCrop = shouldUseFallback
            ? (fallbackCrop ?? bestCandidate?.cropImage)
            : (bestCandidate?.cropImage ?? fallbackCrop)
        let selectedOCR = shouldUseFallback
            ? (fallbackOCR ?? bestCandidate?.ocr)
            : (bestCandidate?.ocr ?? fallbackOCR)
        let previewText = bestCandidate?.block.previewText ?? ""
        let selectedText = normalize(
            selectedOCR?.text
                ?? bestCandidate?.text
                ?? previewText
        )
        let lineCount = selectedOCR?.lineCount ?? bestCandidate?.block.lineCount ?? 0
        let intent = QuestionIntentRecognizer.recognize(text: selectedText, lineCount: lineCount)
        let summary = makeSummary(
            source: source,
            ocr: selectedOCR,
            fallbackUsed: shouldUseFallback,
            previewLineCount: bestCandidate?.block.lineCount ?? 0
        )

        return StillImageQuestionAnalysis(
            detectedRect: selectedRect,
            snapshot: LiveQuestionSnapshot(
                text: selectedText,
                cropImage: selectedCrop,
                intent: intent,
                ocrSummary: summary,
                source: source
            ),
            usedFallbackCrop: shouldUseFallback
        )
    }

    static func cropQuestion(from image: UIImage, normalizedRect: CGRect, padding: CGFloat = 0.08) -> UIImage? {
        let normalizedImage = normalized(image)
        guard let cgImage = normalizedImage.cgImage else {
            return nil
        }

        let paddedRect = expanded(normalizedRect, padding: padding)
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let cropRect = CGRect(
            x: paddedRect.minX * imageBounds.width,
            y: (1 - paddedRect.maxY) * imageBounds.height,
            width: paddedRect.width * imageBounds.width,
            height: paddedRect.height * imageBounds.height
        )
        .integral
        .intersection(imageBounds)

        guard !cropRect.isNull,
              cropRect.width > 24,
              cropRect.height > 24,
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: normalizedImage.scale, orientation: .up)
    }

    private static func recognizeLines(
        with handler: VNImageRequestHandler,
        recognitionLevel: VNRequestTextRecognitionLevel
    ) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.minimumTextHeight = recognitionLevel == .accurate ? 0.010 : 0.016

        do {
            try handler.perform([request])
        } catch {
            return []
        }

        return (request.results ?? []).compactMap { RecognizedLine(observation: $0) }
    }

    private static func recognizeLines(
        in image: UIImage,
        recognitionLevel: VNRequestTextRecognitionLevel
    ) -> [RecognizedLine] {
        guard let cgImage = image.cgImage else {
            return []
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        return recognizeLines(with: handler, recognitionLevel: recognitionLevel)
    }

    private static func bestQuestion(
        from lines: [RecognizedLine],
        focusRect: CGRect,
        mode: QuestionRecognitionMode
    ) -> DetectedQuestionBlock? {
        rankedCandidates(from: lines, focusRect: focusRect, mode: mode)
            .first
            .map { makeDetectedBlock(from: $0.cluster, score: $0.score) }
    }

    private static func rankedCandidates(
        from lines: [RecognizedLine],
        focusRect: CGRect,
        mode: QuestionRecognitionMode
    ) -> [RankedQuestionCandidate] {
        guard !lines.isEmpty else {
            return []
        }

        let candidates = deduplicate(buildSequentialClusters(from: lines) + buildAnchoredClusters(from: lines))
        let minimumScore = mode == .livePreview ? 24.0 : 18.0

        return candidates
            .map { cluster in
                RankedQuestionCandidate(cluster: cluster, score: cluster.score(relativeTo: focusRect))
            }
            .filter { candidate in
                let cluster = candidate.cluster
                let isLivePreview = mode == .livePreview
                let minimumWidth: CGFloat = isLivePreview ? 0.28 : 0.18
                let minimumAspect: CGFloat = isLivePreview ? 1.10 : 0.62
                let minimumCoverage: CGFloat = isLivePreview ? 0.042 : 0.022
                let minimumLineCount = isLivePreview ? 2 : 1
                let minimumWideLineCount = isLivePreview ? 2 : 1
                let minimumMaxLineWidth: CGFloat = isLivePreview ? 0.30 : 0.18

                return cluster.characterCount >= 8
                    && cluster.rect.width >= minimumWidth
                    && cluster.rect.height >= 0.06
                    && cluster.aspectRatio >= minimumAspect
                    && cluster.textCoverage >= minimumCoverage
                    && cluster.lines.count >= minimumLineCount
                    && cluster.wideLineCount >= minimumWideLineCount
                    && cluster.maxLineWidth >= minimumMaxLineWidth
                    && (cluster.promptLineCount >= 1 || !isLivePreview || cluster.characterCount >= 14)
                    && cluster.averageConfidence >= 0.14
                    && candidate.score >= minimumScore
            }
            .sorted { lhs, rhs in
                if abs(lhs.score - rhs.score) > 0.001 {
                    return lhs.score > rhs.score
                }
                return lhs.cluster.characterCount > rhs.cluster.characterCount
            }
    }

    private static func evaluateStillCandidate(
        _ candidate: RankedQuestionCandidate,
        image: UIImage
    ) -> StillCandidateEvaluation? {
        let block = makeDetectedBlock(from: candidate.cluster, score: candidate.score)
        let crop = cropQuestion(from: image, normalizedRect: block.normalizedRect, padding: 0.06)
        let ocr = crop.map { QuestionOCRService.recognizeQuestion(in: $0) }
        let text = normalize(ocr?.text ?? block.previewText)
        let compactText = compact(text)
        let hanCount = regexMatches(#"[\p{Han}]"#, in: text)
        let questionCount = regexMatches(#"(?m)^\s*[（(]?\s*\d{1,3}\s*[）)]?\s*[\.、．]?"#, in: text)
        let promptCount = regexMatches(#"(多少|计算|求|列式|已知|买|每台|每个|学校|下面|判断|选择|填空)"#, in: text)
        let qualityScore = qualityRank(ocr?.quality ?? .weak)
        let aspectRatio = candidate.cluster.aspectRatio
        let aspectPenalty = aspectRatio < 0.85 ? Double((0.85 - aspectRatio) * 120) : 0
        let sparsePenalty = candidate.cluster.textCoverage < 0.03
            ? Double((0.03 - candidate.cluster.textCoverage) * 1200)
            : 0

        let totalScore = candidate.score
            + Double(qualityScore * 28)
            + Double(promptCount * 16)
            + Double(questionCount * 18)
            + Double(min(hanCount, 30)) * 1.1
            + Double(min(compactText.count, 140)) * 0.45
            + Double(candidate.cluster.wideLineCount * 10)
            - aspectPenalty
            - sparsePenalty

        return StillCandidateEvaluation(
            block: block,
            cropImage: crop,
            ocr: ocr,
            text: text,
            totalScore: totalScore
        )
    }

    private static func buildSequentialClusters(from lines: [RecognizedLine]) -> [QuestionCluster] {
        let sorted = sortLines(lines)
        guard let first = sorted.first else {
            return []
        }

        var clusters: [QuestionCluster] = []
        var current = QuestionCluster(lines: [first])

        for line in sorted.dropFirst() {
            if current.canAppend(line) {
                current.lines.append(line)
            } else {
                clusters.append(current)
                current = QuestionCluster(lines: [line])
            }
        }

        clusters.append(current)
        return clusters
    }

    private static func buildAnchoredClusters(from lines: [RecognizedLine]) -> [QuestionCluster] {
        let sorted = sortLines(lines)
        var clusters: [QuestionCluster] = []

        for (index, line) in sorted.enumerated()
        where line.isQuestionAnchor
            || line.hasQuestionPrompt
            || (line.hasProblemSignal && line.rect.width >= 0.16 && line.characterCount >= 5)
        {
            var selection = [line]
            var last = line
            var cursor = index + 1

            while cursor < sorted.count && selection.count < 8 {
                let candidate = sorted[cursor]
                let gap = max(0, last.rect.minY - candidate.rect.maxY)
                if gap > max(0.08, last.rect.height * 2.8) {
                    break
                }

                if candidate.isQuestionAnchor && !selection.isEmpty {
                    break
                }

                selection.append(candidate)
                last = candidate
                cursor += 1
            }

            clusters.append(QuestionCluster(lines: selection))
        }

        return clusters
    }

    private static func sortLines(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > 0.001 {
                return lhs.rect.midY > rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    private static func deduplicate(_ clusters: [QuestionCluster]) -> [QuestionCluster] {
        var seen = Set<String>()
        var unique: [QuestionCluster] = []

        for cluster in clusters {
            let rect = cluster.rect
            let key = [
                Int((rect.minX * 1000).rounded()),
                Int((rect.minY * 1000).rounded()),
                Int((rect.width * 1000).rounded()),
                Int((rect.height * 1000).rounded())
            ]
            .map(String.init)
            .joined(separator: ":")

            if seen.insert(key).inserted {
                unique.append(cluster)
            }
        }

        return unique
    }

    private static func shouldPrefer(_ candidate: QuestionOCRResult?, over current: QuestionOCRResult?) -> Bool {
        guard let candidate else {
            return false
        }

        guard let current else {
            return !candidate.text.isEmpty
        }

        let candidateRank = qualityRank(candidate.quality)
        let currentRank = qualityRank(current.quality)
        if candidateRank != currentRank {
            return candidateRank > currentRank
        }

        return compact(candidate.text).count > compact(current.text).count + 8
    }

    private static func qualityRank(_ quality: QuestionOCRQuality) -> Int {
        switch quality {
        case .good:
            return 3
        case .needsCrop:
            return 2
        case .weak:
            return 1
        }
    }

    private static func makeDetectedBlock(from cluster: QuestionCluster, score: Double) -> DetectedQuestionBlock {
        let text = normalize(cluster.text)
        let rect = expanded(cluster.rect, padding: 0.06)
        let questionNumber = QuestionIntentRecognizer.extractQuestionNumber(from: text)
        let confidence = min(0.98, max(0.38, score / 100))

        return DetectedQuestionBlock(
            normalizedRect: rect,
            previewText: text,
            lineCount: cluster.lines.count,
            confidence: confidence,
            questionNumber: questionNumber,
            blockID: blockID(for: rect, text: text)
        )
    }

    private static func makeSummary(
        source: QuestionResultSource,
        ocr: QuestionOCRResult?,
        fallbackUsed: Bool,
        previewLineCount: Int
    ) -> String {
        let cropMode = fallbackUsed ? "中心兜底裁切" : "单题候选重排"

        guard let ocr else {
            if previewLineCount > 0 {
                return "\(source.rawValue) | 预览 OCR | \(previewLineCount) 行 | \(cropMode)"
            }
            return "\(source.rawValue) | 未识别到清晰文本 | \(cropMode)"
        }

        return "\(source.rawValue) | \(ocr.quality.rawValue) | \(ocr.lineCount) 行 | \(cropMode) | \(ocr.preprocessProfile)"
    }

    private static func preferredFallbackRect(from focusRect: CGRect) -> CGRect {
        let dx = focusRect.width * 0.12
        let dy = focusRect.height * 0.10
        return focusRect.insetBy(dx: dx, dy: dy).clampedToUnitRect()
    }

    private static func expanded(_ rect: CGRect, padding: CGFloat) -> CGRect {
        let dx = max(0.02, rect.width * padding)
        let dy = max(0.02, rect.height * padding)
        return rect.insetBy(dx: -dx, dy: -dy).clampedToUnitRect()
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func compact(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func regexMatches(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    private static func blockID(for rect: CGRect, text: String) -> String {
        let rectKey = [
            Int((rect.midX * 18).rounded()),
            Int((rect.midY * 18).rounded()),
            Int((rect.width * 18).rounded()),
            Int((rect.height * 18).rounded())
        ]
        .map(String.init)
        .joined(separator: ":")

        return "\(rectKey)|\(normalize(text).prefix(24))"
    }

    private static func normalized(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return resized(image, maxDimension: 2400)
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return resized(rendered, maxDimension: 2400)
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else {
            return image
        }

        let scale = maxDimension / longest
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

private enum QuestionRecognitionMode {
    case livePreview
    case stillCapture
}

private struct RankedQuestionCandidate {
    let cluster: QuestionCluster
    let score: Double
}

private struct StillCandidateEvaluation {
    let block: DetectedQuestionBlock
    let cropImage: UIImage?
    let ocr: QuestionOCRResult?
    let text: String
    let totalScore: Double
}

private struct RecognizedLine {
    let text: String
    let rect: CGRect
    let confidence: Float

    init?(observation: VNRecognizedTextObservation) {
        guard let candidate = observation.topCandidates(1).first else {
            return nil
        }

        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let rect = observation.boundingBox.standardized

        guard !text.isEmpty,
              rect.width > 0.025,
              rect.height > 0.010
        else {
            return nil
        }

        self.text = text
        self.rect = rect
        self.confidence = candidate.confidence
    }

    var compactText: String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    var characterCount: Int {
        compactText.count
    }

    var hanCount: Int {
        regexMatches(#"[\p{Han}]"#)
    }

    var digitCount: Int {
        regexMatches(#"[0-9]"#)
    }

    var isQuestionAnchor: Bool {
        matches(#"^\s*[（(]?\d{1,3}[）)]?\s*[\.、．]?"#)
    }

    var hasProblemSignal: Bool {
        matches(#"[0-9+\-×÷=/]"#) || matches(#"(计算|求解|解答|填空|阅读|选择|证明|应用题|方程|函数|choose|translate)"#)
    }

    var hasQuestionPrompt: Bool {
        matches(#"(多少|计算|求|列式|已知|买|每台|每个|学校|下面|判断|选择|填空|完成)"#)
    }

    private func matches(_ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    private func regexMatches(_ pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }
}

private struct QuestionCluster {
    var lines: [RecognizedLine]

    var rect: CGRect {
        lines.dropFirst().reduce(lines[0].rect) { partial, line in
            partial.union(line.rect)
        }
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var characterCount: Int {
        lines.map(\.characterCount).reduce(0, +)
    }

    var averageHeight: CGFloat {
        lines.map(\.rect.height).reduce(0, +) / CGFloat(max(lines.count, 1))
    }

    var averageConfidence: Double {
        Double(lines.map(\.confidence).reduce(0, +)) / Double(max(lines.count, 1))
    }

    var aspectRatio: CGFloat {
        rect.width / max(rect.height, 0.001)
    }

    var textCoverage: CGFloat {
        let textArea = lines.reduce(CGFloat.zero) { partial, line in
            partial + (line.rect.width * line.rect.height)
        }
        return textArea / max(rect.width * rect.height, 0.001)
    }

    var wideLineCount: Int {
        lines.filter { $0.rect.width >= max(0.16, rect.width * 0.40) }.count
    }

    var promptLineCount: Int {
        lines.filter { $0.hasQuestionPrompt || $0.isQuestionAnchor }.count
    }

    var maxLineWidth: CGFloat {
        lines.map(\.rect.width).max() ?? 0
    }

    var leftAlignmentSpread: CGFloat {
        guard let minLeft = lines.map(\.rect.minX).min(),
              let maxLeft = lines.map(\.rect.minX).max() else {
            return 0
        }

        return maxLeft - minLeft
    }

    func score(relativeTo focusRect: CGRect) -> Double {
        let area = rect.width * rect.height
        let anchorCount = lines.filter(\.isQuestionAnchor).count
        let signalCount = lines.filter { $0.hasQuestionPrompt || $0.hasProblemSignal }.count
        let overlap = rect.intersection(focusRect)
        let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
        let focusArea = max(focusRect.width * focusRect.height, 0.001)
        let clusterArea = max(area, 0.001)
        let focusCoverage = overlapArea / focusArea
        let clusterFocusCoverage = overlapArea / clusterArea
        let centerDistance = hypot(rect.midX - focusRect.midX, rect.midY - focusRect.midY)

        let aspectBonus = min(Double(aspectRatio), 3.2) * 26
        let tallPenalty = aspectRatio < 1.05 ? Double((1.05 - aspectRatio) * 220) : 0
        let sparsePenalty = textCoverage < 0.04 ? Double((0.04 - textCoverage) * 1600) : 0
        let densePenalty = textCoverage > 0.42 ? Double((textCoverage - 0.42) * 220) : 0
        let wideLineBonus = Double(wideLineCount * 24)
        let lineWidthBonus = Double(min(maxLineWidth, 0.75) * 52)
        let alignmentPenalty = Double(max(0, leftAlignmentSpread - 0.18) * 90)
        let linePenalty = max(0, lines.count - 8) * 8
        let oversizedPenalty = max(0, area - 0.44) * 190
        let multiAnchorPenalty = max(0, anchorCount - 1) * 18

        return Double(characterCount) * 1.8
            + Double(lines.count * 12)
            + averageConfidence * 36
            + focusCoverage * 110
            + clusterFocusCoverage * 34
            + wideLineBonus
            + lineWidthBonus
            + aspectBonus
            + Double(signalCount * 22)
            + max(0, 1 - Double(centerDistance) * 3.2) * 20
            - tallPenalty
            - sparsePenalty
            - densePenalty
            - alignmentPenalty
            - Double(linePenalty)
            - Double(multiAnchorPenalty)
            - oversizedPenalty
    }

    func canAppend(_ line: RecognizedLine) -> Bool {
        guard let last = lines.last else {
            return true
        }

        if line.isQuestionAnchor {
            return false
        }

        let gap = max(0, last.rect.minY - line.rect.maxY)
        let overlap = rect.intersection(line.rect)
        let overlapWidth = overlap.isNull ? 0 : overlap.width
        let horizontalOverlap = overlapWidth / max(min(rect.width, line.rect.width), 0.001)
        let centerDistance = abs(rect.midX - line.rect.midX)
        let leftShift = abs(line.rect.minX - last.rect.minX)

        return gap <= max(0.065, averageHeight * 2.4)
            && centerDistance < 0.34
            && leftShift < 0.26
            && (horizontalOverlap > 0.08 || line.rect.width > max(0.15, rect.width * 0.40))
    }
}

private extension CGRect {
    func clampedToUnitRect() -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return intersection(unit)
    }
}
