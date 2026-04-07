import dotenv from "dotenv";

dotenv.config();

export const config = {
  port: Number(process.env.PORT || 21080),
  openAIApiKey: process.env.OPENAI_API_KEY || "",
  openAIBaseUrl: process.env.OPENAI_BASE_URL || "https://api.openai.com/v1",
  model: process.env.MODEL || "gpt-5.4",
  fallbackModel: process.env.FALLBACK_MODEL || "gpt-4.1-mini",
  allowedOrigin: process.env.ALLOWED_ORIGIN || "*"
};

if (!config.openAIApiKey) {
  console.warn("OPENAI_API_KEY is not set. Solver requests will fail until it is configured.");
}
