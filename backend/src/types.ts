export type ProblemSubject = "math" | "chinese" | "english" | "science" | "general";

export type AnswerStyle = "guided" | "detailed" | "direct";

export interface SolveClientTrace {
  source?: "camera" | "photoLibrary";
  recognizer?: string;
  preprocessProfile?: string;
  cropApplied?: boolean;
  ocrQuality?: string;
  ocrQualityReason?: string;
  ocrDurationMs?: number;
  recognizedLineCount?: number;
  recognizedTextLength?: number;
  imageWidth?: number;
  imageHeight?: number;
  imageBytes?: number;
  originalImageWidth?: number;
  originalImageHeight?: number;
  ocrAverageConfidence?: number;
  ocrPass?: string;
  autoCropApplied?: boolean;
  autoCropCoverage?: number;
  ocrWarnings?: string[];
  appVersion?: string;
  buildNumber?: string;
  clientStartedAt?: string;
}

export interface SolveProblemPayload {
  sessionId?: string;
  subject: ProblemSubject;
  gradeBand: string;
  answerStyle: AnswerStyle;
  questionHint?: string;
  recognizedText?: string;
  imageBase64: string;
  clientTrace?: SolveClientTrace;
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

export interface SolveProblemExecution {
  result: SolveProblemResult;
  pipelineRoute: "local" | "model_text_only" | "model_vision" | "heuristic_fallback";
  usedModel: string;
}

export interface AnalyzeSolveResponse extends SolveProblemResult {
  traceId: string;
  sessionId: string;
  sessionSummary: string;
  turnCount: number;
  pipelineRoute: string;
  usedModel: string;
  processingMs: number;
}

export interface SessionTurn {
  at: string;
  question: string;
  answer: string;
  subject: string;
}
