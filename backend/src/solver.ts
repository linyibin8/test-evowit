import { z } from "zod";
import { openai } from "./openai.js";
import { config } from "./config.js";
import { buildSolverPrompt, solverSystemPrompt } from "./prompts.js";
import { extractQuestionText, normalizeText, solveWithHeuristics, tryLocalSolve } from "./local-solver.js";
import type { TraceLogger } from "./trace-logger.js";
import type { SolveProblemExecution, SolveProblemPayload, SolveProblemResult } from "./types.js";

const solveResultSchema = z.object({
  problemText: z.string(),
  cleanedQuestion: z.string(),
  inferredSubject: z.string(),
  problemType: z.string(),
  difficulty: z.string(),
  answer: z.string(),
  keySteps: z.array(z.string()),
  fullExplanation: z.string(),
  knowledgePoints: z.array(z.string()),
  commonMistakes: z.array(z.string()),
  followUpPractice: z.string(),
  encouragement: z.string(),
  confidence: z.number().min(0).max(1),
  shouldRetakePhoto: z.boolean(),
  retakeReason: z.string()
});

function getStatusCode(error: unknown) {
  if (typeof error === "object" && error && "status" in error) {
    return Number(error.status);
  }

  return undefined;
}

function isAbortError(error: unknown) {
  return error instanceof Error && error.name === "AbortError";
}

function canRetryModel(error: unknown) {
  const status = getStatusCode(error);
  return isAbortError(error) || status === 408 || status === 409 || status === 429 || (status !== undefined && status >= 500);
}

function trimResult(result: SolveProblemResult) {
  return {
    cleanedQuestion: result.cleanedQuestion,
    answer: result.answer,
    confidence: result.confidence,
    shouldRetakePhoto: result.shouldRetakePhoto
  };
}

function assessRecognizedText(payload: SolveProblemPayload) {
  const normalized = normalizeText(payload.recognizedText || "");
  const compact = normalized.replace(/\s+/g, "");
  const lineCount = normalized ? normalized.split("\n").filter(Boolean).length : 0;
  const suspiciousCharCount = (compact.match(/[�□]/g) || []).length;
  const suspiciousRatio = compact.length > 0 ? suspiciousCharCount / compact.length : 1;
  const mathSignal = /[0-9x=+\-*/()]/.test(normalized);
  const textStrong = compact.length >= 24 && suspiciousRatio < 0.08;
  const mathStrong = mathSignal && compact.length >= 6 && suspiciousRatio < 0.15;

  return {
    normalized,
    compactLength: compact.length,
    lineCount,
    suspiciousRatio,
    mathSignal,
    hasUsefulText: compact.length >= 6,
    shouldUseTextOnly: textStrong || mathStrong
  };
}

function buildRequestPayload(
  payload: SolveProblemPayload,
  sessionSummary: string | undefined,
  mode: "text_only" | "vision"
) {
  const prompt = buildSolverPrompt(payload, sessionSummary);
  const reasoningEffort = mode === "text_only" ? "low" : config.modelReasoningEffort;
  const content =
    mode === "vision"
      ? [
          {
            type: "input_text" as const,
            text: prompt
          },
          {
            type: "input_image" as const,
            image_url: `data:image/jpeg;base64,${payload.imageBase64}`,
            detail: config.visionImageDetail as "low" | "high" | "auto"
          }
        ]
      : [
          {
            type: "input_text" as const,
            text: prompt
          }
        ];

  return {
    prompt,
    request: {
      reasoning: { effort: reasoningEffort as "low" | "medium" | "high" },
      max_output_tokens: mode === "text_only" ? 1200 : 1600,
      text: {
        format: {
          type: "json_schema" as const,
          name: "solve_problem",
          schema: {
            type: "object",
            additionalProperties: false,
            properties: {
              problemText: { type: "string" },
              cleanedQuestion: { type: "string" },
              inferredSubject: { type: "string" },
              problemType: { type: "string" },
              difficulty: { type: "string" },
              answer: { type: "string" },
              keySteps: {
                type: "array",
                items: { type: "string" }
              },
              fullExplanation: { type: "string" },
              knowledgePoints: {
                type: "array",
                items: { type: "string" }
              },
              commonMistakes: {
                type: "array",
                items: { type: "string" }
              },
              followUpPractice: { type: "string" },
              encouragement: { type: "string" },
              confidence: { type: "number" },
              shouldRetakePhoto: { type: "boolean" },
              retakeReason: { type: "string" }
            },
            required: [
              "problemText",
              "cleanedQuestion",
              "inferredSubject",
              "problemType",
              "difficulty",
              "answer",
              "keySteps",
              "fullExplanation",
              "knowledgePoints",
              "commonMistakes",
              "followUpPractice",
              "encouragement",
              "confidence",
              "shouldRetakePhoto",
              "retakeReason"
            ]
          }
        }
      },
      input: [
        {
          role: "system" as const,
          content: [{ type: "input_text" as const, text: solverSystemPrompt }]
        },
        {
          role: "user" as const,
          content
        }
      ]
    }
  };
}

async function callModel(
  model: string,
  payload: SolveProblemPayload,
  sessionSummary: string | undefined,
  mode: "text_only" | "vision",
  trace?: TraceLogger
) {
  const { prompt, request } = buildRequestPayload(payload, sessionSummary, mode);
  trace?.setPrompt(solverSystemPrompt, prompt);
  trace?.addModelAttempt({
    model,
    mode,
    reasoningEffort: mode === "text_only" ? "low" : config.modelReasoningEffort,
    visionImageDetail: mode === "vision" ? config.visionImageDetail : "none"
  });

  const response = await openai.responses.create(
    {
      model,
      ...request
    },
    {
      signal: AbortSignal.timeout(config.modelTimeoutMs)
    }
  );

  const parsed = solveResultSchema.parse(JSON.parse(response.output_text));
  return parsed;
}

export async function solveProblem(
  payload: SolveProblemPayload,
  sessionSummary?: string,
  trace?: TraceLogger
): Promise<SolveProblemExecution> {
  const questionText = extractQuestionText(payload);
  const textAssessment = assessRecognizedText(payload);

  trace?.step("input_assessed", {
    questionTextPreview: questionText.slice(0, 200),
    recognizedTextLength: textAssessment.compactLength,
    recognizedLineCount: textAssessment.lineCount,
    suspiciousRatio: Number(textAssessment.suspiciousRatio.toFixed(4)),
    shouldUseTextOnly: textAssessment.shouldUseTextOnly
  });

  const localSolved = tryLocalSolve(payload);
  if (localSolved) {
    trace?.setRouting({
      selectedRoute: "local",
      reason: "基础数学题命中本地求解器",
      textAssessment
    });

    return {
      result: localSolved,
      pipelineRoute: "local",
      usedModel: "local-solver"
    };
  }

  const preferredMode = textAssessment.shouldUseTextOnly ? "text_only" : "vision";
  trace?.setRouting({
    selectedRoute: preferredMode === "text_only" ? "model_text_only" : "model_vision",
    reason:
      preferredMode === "text_only"
        ? "本地 OCR 文本足够清晰，优先走纯文本模型调用"
        : "OCR 文本不足，需要携带图片走视觉模型调用",
    textAssessment
  });

  const candidateModels =
    config.fallbackModel && config.fallbackModel !== config.model
      ? [config.model, config.fallbackModel]
      : [config.model];

  let lastError: unknown;
  for (let index = 0; index < candidateModels.length; index += 1) {
    const model = candidateModels[index];
    try {
      const result = await callModel(model, payload, sessionSummary, preferredMode, trace);
      return {
        result,
        pipelineRoute: preferredMode === "text_only" ? "model_text_only" : "model_vision",
        usedModel: model
      };
    } catch (error) {
      lastError = error;
      trace?.step("model_attempt_failed", {
        model,
        attempt: index + 1,
        message: error instanceof Error ? error.message : String(error),
        status: getStatusCode(error),
        abort: isAbortError(error)
      });

      if (!canRetryModel(error) || index === candidateModels.length - 1) {
        break;
      }
    }
  }

  trace?.step("heuristic_fallback", {
    reason: lastError instanceof Error ? lastError.message : String(lastError)
  });

  return {
    result: solveWithHeuristics(payload),
    pipelineRoute: "heuristic_fallback",
    usedModel: "heuristic-fallback"
  };
}
