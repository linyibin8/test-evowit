import Foundation

enum QuestionIntentRecognizer {
    static func recognize(text: String, lineCount: Int) -> LiveQuestionIntentInfo? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else {
            return nil
        }

        let questionNumber = extractQuestionNumber(from: normalized)
        let subject = detectSubject(in: normalized)
        let intent = detectIntent(in: normalized, lineCount: lineCount)
        let signals = collectSignals(in: normalized, lineCount: lineCount, subject: subject, intent: intent)
        let confidence = confidenceScore(for: normalized, lineCount: lineCount, subject: subject, intent: intent)

        return LiveQuestionIntentInfo(
            questionNumber: questionNumber,
            subject: subject,
            intent: intent,
            confidence: confidence,
            signals: signals
        )
    }

    static func extractQuestionNumber(from text: String) -> String? {
        firstMatch(
            pattern: #"(?m)^\s*[（(]?\s*(\d{1,3})\s*[）)]?\s*[\.、．]?"#,
            in: text
        )
    }

    private static func detectSubject(in text: String) -> LiveQuestionSubject {
        var scores: [LiveQuestionSubject: Int] = [
            .math: 0,
            .chinese: 0,
            .english: 0,
            .science: 0,
            .general: 0
        ]

        scores[.math, default: 0] += keywordScore(
            in: text,
            keywords: ["计算", "方程", "分数", "函数", "几何", "求值", "求解", "厘米", "面积", "周长"]
        )
        scores[.math, default: 0] += regexMatches(#"[0-9+\-×÷=/%()]"#, in: text) * 2

        scores[.english, default: 0] += keywordScore(
            in: text,
            keywords: ["translate", "english", "阅读下列短文", "选出", "完形填空", "单词", "句子", "choose"]
        )
        scores[.english, default: 0] += regexMatches(#"\b[a-zA-Z]{3,}\b"#, in: text) * 2

        scores[.chinese, default: 0] += keywordScore(
            in: text,
            keywords: ["阅读", "作文", "拼音", "词语", "古诗", "修辞", "病句", "文段"]
        )

        scores[.science, default: 0] += keywordScore(
            in: text,
            keywords: ["实验", "物理", "化学", "生物", "电路", "速度", "质量", "温度", "溶液", "压强"]
        )
        scores[.science, default: 0] += regexMatches(#"(cm|mm|kg|g|m/s|℃|°C|mol|N)"#, in: text) * 2

        let sorted = scores.sorted { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key.rawValue < rhs.key.rawValue
            }
            return lhs.value > rhs.value
        }

        guard let best = sorted.first, best.value > 0 else {
            return .general
        }

        return best.key
    }

    private static func detectIntent(in text: String, lineCount: Int) -> LiveQuestionIntentKind {
        if regexMatches(#"(?m)^\s*[A-D][\.．、:：)]"#, in: text) >= 2
            || containsAny(text, ["单选", "多选", "选择正确", "choose the best", "选出"]) {
            return .multipleChoice
        }

        if containsAny(text, ["填空", "横线", "blank", "补全", "____", "___"]) {
            return .fillBlank
        }

        if containsAny(text, ["阅读下面", "阅读材料", "短文", "阅读并回答", "passage"])
            || (lineCount >= 5 && text.count >= 80 && containsAny(text, ["回答问题", "下列材料", "根据短文"])) {
            return .reading
        }

        if containsAny(text, ["为什么", "说明理由", "证明", "分析", "解答", "简述", "列式并计算"]) {
            return .explanation
        }

        if containsAny(text, ["计算", "求", "求出", "解方程", "列式"])
            || regexMatches(#"[+\-×÷=]"#, in: text) >= 2 {
            return .calculation
        }

        return .unknown
    }

    private static func collectSignals(
        in text: String,
        lineCount: Int,
        subject: LiveQuestionSubject,
        intent: LiveQuestionIntentKind
    ) -> [String] {
        var signals: [String] = []

        if let questionNumber = extractQuestionNumber(from: text) {
            signals.append("题号 \(questionNumber)")
        }

        if lineCount > 0 {
            signals.append("\(lineCount) 行")
        }

        if subject != .general {
            signals.append(subject.rawValue)
        }

        if intent != .unknown {
            signals.append(intent.rawValue)
        }

        if regexMatches(#"[0-9+\-×÷=]"#, in: text) >= 3 {
            signals.append("公式信号")
        }

        if regexMatches(#"\b[a-zA-Z]{3,}\b"#, in: text) >= 3 {
            signals.append("英文信号")
        }

        return signals
    }

    private static func confidenceScore(
        for text: String,
        lineCount: Int,
        subject: LiveQuestionSubject,
        intent: LiveQuestionIntentKind
    ) -> Double {
        var score = 0.46
        score += min(Double(text.count) / 220, 0.18)
        score += min(Double(lineCount) / 12, 0.12)

        if subject != .general {
            score += 0.1
        }

        if intent != .unknown {
            score += 0.1
        }

        if extractQuestionNumber(from: text) != nil {
            score += 0.08
        }

        return min(0.98, score)
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func keywordScore(in text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { partial, keyword in
            partial + (text.localizedCaseInsensitiveContains(keyword) ? 4 : 0)
        }
    }

    private static func regexMatches(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let textRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[textRange])
    }
}
