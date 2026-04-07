import { z } from "zod";
import { openai } from "./openai.js";
import { config } from "./config.js";
import { solveWithHeuristics } from "./local-solver.js";
import { buildSolverPrompt, solverSystemPrompt } from "./prompts.js";
import type { SolveProblemPayload, SolveProblemResult } from "./types.js";

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

export async function solveProblem(
  payload: SolveProblemPayload,
  sessionSummary?: string
): Promise<SolveProblemResult> {
  const request = {
    reasoning: { effort: "high" as const },
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
        content: [
          {
            type: "input_text" as const,
            text: buildSolverPrompt(payload, sessionSummary)
          },
          {
            type: "input_image" as const,
            image_url: `data:image/jpeg;base64,${payload.imageBase64}`,
            detail: "high" as const
          }
        ]
      }
    ]
  };

  let response;
  try {
    response = await openai.responses.create({
      model: config.model,
      ...request
    });
  } catch (error) {
    const status = typeof error === "object" && error && "status" in error ? Number(error.status) : undefined;
    if (status === 429 && config.fallbackModel && config.fallbackModel !== config.model) {
      try {
        response = await openai.responses.create({
          model: config.fallbackModel,
          ...request
        });
      } catch (fallbackError) {
        const fallbackStatus =
          typeof fallbackError === "object" && fallbackError && "status" in fallbackError
            ? Number(fallbackError.status)
            : undefined;
        if (fallbackStatus === 429) {
          return solveWithHeuristics(payload);
        }
        throw fallbackError;
      }
    } else if (status === 429) {
      return solveWithHeuristics(payload);
    } else {
      throw error;
    }
  }

  return solveResultSchema.parse(JSON.parse(response.output_text));
}
