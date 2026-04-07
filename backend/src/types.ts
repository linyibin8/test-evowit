export type ProblemSubject = "math" | "chinese" | "english" | "science" | "general";

export type AnswerStyle = "guided" | "detailed" | "direct";

export interface SolveProblemPayload {
  sessionId?: string;
  subject: ProblemSubject;
  gradeBand: string;
  answerStyle: AnswerStyle;
  questionHint?: string;
  recognizedText?: string;
  imageBase64: string;
}

export interface SolveProblemResult {
  problemText: string;
  cleanedQuestion: string;
  inferredSubject: string;
  problemType: string;
  difficulty: string;
  answer: string;
  keySteps: string[];
  fullExplanation: string;
  knowledgePoints: string[];
  commonMistakes: string[];
  followUpPractice: string;
  encouragement: string;
  confidence: number;
  shouldRetakePhoto: boolean;
  retakeReason: string;
}

export interface AnalyzeSolveResponse extends SolveProblemResult {
  sessionId: string;
  sessionSummary: string;
  turnCount: number;
}

export interface SessionTurn {
  at: string;
  question: string;
  answer: string;
  subject: string;
}
