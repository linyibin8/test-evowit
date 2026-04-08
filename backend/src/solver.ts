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

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function canRetryModel(error: unknown) {
  const status = getStatusCode(error);
  const message = getErrorMessage(error).toLowerCase();
  const timeoutLike =
    message.includes("abort") ||
    message.includes("timed out") ||
    message.includes("timeout") ||
    message.includes("deadline") ||
    message.includes("econnreset");

  return (
    isAbortError(error) ||
    timeoutLike ||
    status === 408 ||
    status === 409 ||
    status === 429 ||
    (status !== undefined && status >= 500)
  );
}

function assessRecognizedText(payload: SolveProblemPayload) {
  const normalized = normalizeText(payload.recognizedText || "");
  const compact = normalized.replace(/\s+/g, "");
  const lines = normalized
    ? normalized
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean)
    : [];
  const lineCount = lines.length;
  const shortLineCount = lines.filter((line) => line.length <= 4).length;
  const shortLineRatio = lineCount > 0 ? shortLineCount / lineCount : 0;
  const suspiciousCharCount = (compact.match(/[�□锟解枴]/g) || []).length;
  const suspiciousRatio = compact.length > 0 ? suspiciousCharCount / compact.length : 1;
  const mathSignal = /[0-9x=+\-*/()]/.test(normalized);
  const latinNoiseCount = (normalized.match(/[A-Za-z]{2,}/g) || []).length;
  const weirdSymbolCount = (normalized.match(/[⅓⅔⅛①②③④⑤⑥⑦⑧⑨⑩]/g) || []).length;
  const numberedQuestionCount = (normalized.match(/(?:^|\n)\s*\d+[.)、．]/g) || []).length;
  const likelyWorksheet = lineCount >= 8 || compact.length >= 180 || numberedQuestionCount >= 2;
  const noisyOcr = shortLineRatio >= 0.28 || latinNoiseCount >= 2 || weirdSymbolCount >= 2;
  const textStrong =
    compact.length >= 24 &&
    compact.length <= 120 &&
    lineCount <= 6 &&
    suspiciousRatio < 0.08 &&
    !noisyOcr;
  const mathStrong =
    mathSignal &&
    compact.length >= 6 &&
    compact.length <= 80 &&
    lineCount <= 4 &&
    suspiciousRatio < 0.15 &&
    !noisyOcr;

  return {
    normalized,
    compactLength: compact.length,
    lineCount,
    shortLineRatio,
    suspiciousRatio,
    mathSignal,
    latinNoiseCount,
    weirdSymbolCount,
    numberedQuestionCount,
    likelyWorksheet,
    noisyOcr,
    hasUsefulText: compact.length >= 6,
    shouldUseTextOnly: !likelyWorksheet && (textStrong || mathStrong)
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

function buildRetakeFallback(
  questionText: string,
  reason: string,
  inferredSubject: string
): SolveProblemResult {
  return {
    problemText: questionText,
    cleanedQuestion: questionText,
    inferredSubject,
    problemType: "需要重新拍题",
    difficulty: "待识别",
    answer: "当前照片更像整页作业或题干噪声较大，继续强行作答很容易答错。",
    keySteps: [
      "已经识别到部分题干，但这不是稳定的单题输入。",
      "建议先裁切到一道题，再重新拍照或补充完整题干。"
    ],
    fullExplanation: "当前输入里包含多行、多题或较多 OCR 噪声，直接作答会把不同题目混在一起。先框出单题再识别，准确率会明显更高。",
    knowledgePoints: ["单题拍照", "OCR 识别质量"],
    commonMistakes: ["整页一起拍", "题干没拍完整", "照片过斜或反光"],
    followUpPractice: "把图片裁成只保留一道题后，再重新解析。",
    encouragement: "这类题先拍成单题，后面的讲解会稳定很多。",
    confidence: 0.2,
    shouldRetakePhoto: true,
    retakeReason: reason
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
      signal: AbortSignal.timeout(mode === "text_only" ? Math.min(config.modelTimeoutMs, 18000) : config.modelTimeoutMs)
    }
  );

  return solveResultSchema.parse(JSON.parse(response.output_text));
}

export async function solveProblem(
  payload: SolveProblemPayload,
  sessionSummary?: string,
  trace?: TraceLogger
): Promise<SolveProblemExecution> {
  const questionText = extractQuestionText(payload);
  const textAssessment = assessRecognizedText(payload);
  const inferredSubject = payload.subject === "math" ? "数学" : "通用";

  trace?.step("ocr_text_assessed", {
    questionTextPreview: questionText.slice(0, 200),
    recognizedTextLength: textAssessment.compactLength,
    recognizedLineCount: textAssessment.lineCount,
    shortLineRatio: Number(textAssessment.shortLineRatio.toFixed(4)),
    suspiciousRatio: Number(textAssessment.suspiciousRatio.toFixed(4)),
    latinNoiseCount: textAssessment.latinNoiseCount,
    weirdSymbolCount: textAssessment.weirdSymbolCount,
    numberedQuestionCount: textAssessment.numberedQuestionCount,
    likelyWorksheet: textAssessment.likelyWorksheet,
    noisyOcr: textAssessment.noisyOcr,
    shouldUseTextOnly: textAssessment.shouldUseTextOnly
  });

  const localSolved = tryLocalSolve(payload);
  trace?.step("local_solver_checked", {
    matched: Boolean(localSolved),
    subject: payload.subject
  });

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
  const selectedRoute = preferredMode === "text_only" ? "model_text_only" : "model_vision";
  const routeReason =
    preferredMode === "text_only"
      ? "OCR 文本清晰且更像单题，优先走纯文本模型调用"
      : "OCR 文本不足、像整页题单或噪声较高，改走带图片的视觉模型调用";

  trace?.setRouting({
    selectedRoute,
    reason: routeReason,
    textAssessment
  });
  trace?.step("route_selected", {
    selectedRoute,
    reason: routeReason
  });

  const candidateModels =
    config.fallbackModel && config.fallbackModel !== config.model
      ? [config.model, config.fallbackModel]
      : [config.model];
  const candidateModes =
    preferredMode === "text_only" && payload.imageBase64 ? (["text_only", "vision"] as const) : ([preferredMode] as const);

  let lastError: unknown;

  for (let modeIndex = 0; modeIndex < candidateModes.length; modeIndex += 1) {
    const mode = candidateModes[modeIndex];

    if (modeIndex > 0) {
      trace?.step("retry_mode_selected", {
        from: candidateModes[modeIndex - 1],
        to: mode,
        reason: "text_only_failed"
      });
    }

    for (let modelIndex = 0; modelIndex < candidateModels.length; modelIndex += 1) {
      const model = candidateModels[modelIndex];

      try {
        const result = await callModel(model, payload, sessionSummary, mode, trace);
        trace?.step("model_attempt_succeeded", {
          model,
          mode,
          attempt: modelIndex + 1,
          modeAttempt: modeIndex + 1
        });

        return {
          result,
          pipelineRoute: mode === "text_only" ? "model_text_only" : "model_vision",
          usedModel: model
        };
      } catch (error) {
        lastError = error;
        const retryable = canRetryModel(error);

        trace?.step("model_attempt_failed", {
          model,
          mode,
          attempt: modelIndex + 1,
          modeAttempt: modeIndex + 1,
          message: getErrorMessage(error),
          status: getStatusCode(error),
          abort: isAbortError(error),
          retryable
        });

        const hasMoreModels = modelIndex < candidateModels.length - 1;
        if (!retryable || !hasMoreModels) {
          break;
        }
      }
    }
  }

  trace?.step("heuristic_fallback", {
    reason: getErrorMessage(lastError)
  });

  if (textAssessment.likelyWorksheet || textAssessment.noisyOcr) {
    return {
      result: buildRetakeFallback(
        questionText,
        "当前照片更像整页作业或题干噪声较大，请裁切到单题后重拍。",
        inferredSubject
      ),
      pipelineRoute: "heuristic_fallback",
      usedModel: "retake-required"
    };
  }

  return {
    result: solveWithHeuristics(payload),
    pipelineRoute: "heuristic_fallback",
    usedModel: "heuristic-fallback"
  };
}
