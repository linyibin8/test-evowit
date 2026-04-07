import Foundation

enum ProblemSubject: String, CaseIterable, Identifiable, Codable {
    case math
    case chinese
    case english
    case science
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .math: return "数学"
        case .chinese: return "语文"
        case .english: return "英语"
        case .science: return "科学"
        case .general: return "通用"
        }
    }
}

enum AnswerStyle: String, CaseIterable, Identifiable, Codable {
    case guided
    case detailed
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guided: return "启发式"
        case .detailed: return "详细解析"
        case .direct: return "直接答案"
        }
    }
}

enum GradeBand: String, CaseIterable, Identifiable, Codable {
    case primary = "小学"
    case middleSchool = "初中"
    case highSchool = "高中"
    case college = "大学"

    var id: String { rawValue }
}

struct SolveProblemRequest: Codable {
    let sessionId: String?
    let subject: String
    let gradeBand: String
    let answerStyle: String
    let questionHint: String?
    let recognizedText: String?
    let imageBase64: String
}

struct SolveProblemResponse: Codable, Identifiable {
    let sessionId: String
    let problemText: String
    let cleanedQuestion: String
    let inferredSubject: String
    let problemType: String
    let difficulty: String
    let answer: String
    let keySteps: [String]
    let fullExplanation: String
    let knowledgePoints: [String]
    let commonMistakes: [String]
    let followUpPractice: String
    let encouragement: String
    let confidence: Double
    let shouldRetakePhoto: Bool
    let retakeReason: String
    let sessionSummary: String
    let turnCount: Int

    var id: String { "\(sessionId)-\(turnCount)" }
}

struct SolveHistoryItem: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let thumbnailData: Data
    let problemText: String
    let answer: String
}
