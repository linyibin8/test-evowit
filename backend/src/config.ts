import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";

dotenv.config();

const repoRoot = path.resolve(fileURLToPath(new URL("../..", import.meta.url)));

export const config = {
  port: Number(process.env.PORT || 21080),
  openAIApiKey: process.env.OPENAI_API_KEY || "",
  openAIBaseUrl: process.env.OPENAI_BASE_URL || "https://api.openai.com/v1",
  model: process.env.MODEL || "gpt-5.4",
  fallbackModel: process.env.FALLBACK_MODEL || "gpt-4.1-mini",
  modelReasoningEffort: process.env.MODEL_REASONING_EFFORT || "medium",
  modelTimeoutMs: Number(process.env.MODEL_TIMEOUT_MS || 30000),
  visionImageDetail: process.env.VISION_IMAGE_DETAIL || "low",
  allowedOrigin: process.env.ALLOWED_ORIGIN || "*",
  logDir: process.env.LOG_DIR || path.join(repoRoot, "output")
};

if (!config.openAIApiKey) {
  console.warn("OPENAI_API_KEY is not set. Solver requests will fail until it is configured.");
}
