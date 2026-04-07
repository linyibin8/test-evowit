import cors from "cors";
import express from "express";
import { fileURLToPath } from "node:url";
import multer from "multer";
import { z } from "zod";
import { config } from "./config.js";
import { appendTurn, getOrCreateSession, getSessionSummary } from "./session-store.js";
import { solveProblem } from "./solver.js";
import type { AnalyzeSolveResponse, SolveProblemPayload } from "./types.js";

const app = express();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 12 * 1024 * 1024 } });

app.use(cors({ origin: config.allowedOrigin }));
app.use(express.json({ limit: "20mb" }));
app.use(express.static(fileURLToPath(new URL("../public", import.meta.url))));

const solveSchema = z.object({
  sessionId: z.string().uuid().optional(),
  subject: z.enum(["math", "chinese", "english", "science", "general"]),
  gradeBand: z.string().min(1),
  answerStyle: z.enum(["guided", "detailed", "direct"]),
  questionHint: z.string().optional(),
  recognizedText: z.string().optional(),
  imageBase64: z.string().min(32)
});

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    model: config.model,
    fallbackModel: config.fallbackModel,
    port: config.port
  });
});

app.post("/api/solve", async (req, res) => {
  try {
    const payload = solveSchema.parse(req.body) as SolveProblemPayload;
    const session = getOrCreateSession(payload);
    const prior = getSessionSummary(session.id);
    const result = await solveProblem({ ...payload, sessionId: session.id }, prior.summary);
    appendTurn(session.id, payload, result);
    const summary = getSessionSummary(session.id);

    const response: AnalyzeSolveResponse = {
      ...result,
      sessionId: session.id,
      sessionSummary: summary.summary,
      turnCount: summary.turnCount
    };

    res.json(response);
  } catch (error) {
    console.error(error);
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.post("/api/solve/upload", upload.single("image"), async (req, res) => {
  try {
    if (!req.file) {
      res.status(400).json({ error: "image file is required" });
      return;
    }

    const payload: SolveProblemPayload = {
      sessionId: req.body.sessionId ? String(req.body.sessionId) : undefined,
      subject: solveSchema.shape.subject.parse(String(req.body.subject || "math")),
      gradeBand: String(req.body.gradeBand || "初中"),
      answerStyle: solveSchema.shape.answerStyle.parse(String(req.body.answerStyle || "guided")),
      questionHint: req.body.questionHint ? String(req.body.questionHint) : undefined,
      recognizedText: req.body.recognizedText ? String(req.body.recognizedText) : undefined,
      imageBase64: req.file.buffer.toString("base64")
    };

    const session = getOrCreateSession(payload);
    const prior = getSessionSummary(session.id);
    const result = await solveProblem({ ...payload, sessionId: session.id }, prior.summary);
    appendTurn(session.id, payload, result);
    const summary = getSessionSummary(session.id);

    const response: AnalyzeSolveResponse = {
      ...result,
      sessionId: session.id,
      sessionSummary: summary.summary,
      turnCount: summary.turnCount
    };

    res.json(response);
  } catch (error) {
    console.error(error);
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.listen(config.port, "0.0.0.0", () => {
  console.log(`test-evowit backend listening on ${config.port}`);
});
