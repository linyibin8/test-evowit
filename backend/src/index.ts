import cors from "cors";
import crypto from "node:crypto";
import express from "express";
import { fileURLToPath } from "node:url";
import multer from "multer";
import { z } from "zod";
import { config } from "./config.js";
import { detectQuestionCrop } from "./layout-service.js";
import { appendTurn, getOrCreateSession, getSessionSummary } from "./session-store.js";
import { solveProblem } from "./solver.js";
import { getTrace, listTraces, subscribeTraceEvents, summarizeTraces, TraceLogger } from "./trace-logger.js";
import type { AnalyzeSolveResponse, SolveClientTrace, SolveProblemExecution, SolveProblemPayload } from "./types.js";

const app = express();
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 12 * 1024 * 1024 } });

app.use(cors({ origin: config.allowedOrigin }));
app.use(express.json({ limit: "20mb" }));
app.use(express.static(fileURLToPath(new URL("../public", import.meta.url))));

const normalizedRectSchema = z.object({
  x: z.number().min(0).max(1),
  y: z.number().min(0).max(1),
  width: z.number().positive().max(1),
  height: z.number().positive().max(1)
});

const clientTraceSchema = z
  .object({
    source: z.enum(["camera", "photoLibrary"]).optional(),
    recognizer: z.string().optional(),
    preprocessProfile: z.string().optional(),
    cropApplied: z.boolean().optional(),
    ocrQuality: z.string().optional(),
    ocrQualityReason: z.string().optional(),
    ocrDurationMs: z.number().nonnegative().optional(),
    recognizedLineCount: z.number().int().nonnegative().optional(),
    recognizedTextLength: z.number().int().nonnegative().optional(),
    imageWidth: z.number().int().nonnegative().optional(),
    imageHeight: z.number().int().nonnegative().optional(),
    imageBytes: z.number().int().nonnegative().optional(),
    originalImageWidth: z.number().int().nonnegative().optional(),
    originalImageHeight: z.number().int().nonnegative().optional(),
    ocrAverageConfidence: z.number().min(0).max(1).optional(),
    ocrPass: z.string().optional(),
    autoCropApplied: z.boolean().optional(),
    autoCropSource: z.string().optional(),
    autoCropCoverage: z.number().min(0).max(1).optional(),
    ocrWarnings: z.array(z.string()).optional(),
    captureProfile: z.string().optional(),
    lockFramesRequired: z.number().int().positive().optional(),
    previewAnalysisIntervalMs: z.number().int().positive().optional(),
    serverRequestIntervalMs: z.number().int().positive().optional(),
    focusRect: normalizedRectSchema.optional(),
    appVersion: z.string().optional(),
    buildNumber: z.string().optional(),
    clientStartedAt: z.string().optional()
  })
  .partial();

const solveSchema = z.object({
  sessionId: z.string().uuid().optional(),
  subject: z.enum(["math", "chinese", "english", "science", "general"]),
  gradeBand: z.string().min(1),
  answerStyle: z.enum(["guided", "detailed", "direct"]),
  questionHint: z.string().optional(),
  recognizedText: z.string().optional(),
  imageBase64: z.string().min(32),
  clientTrace: clientTraceSchema.optional()
});

const detectQuestionSchema = z.object({
  imageBase64: z.string().min(32),
  focusRect: normalizedRectSchema.optional()
});

function parseClientTrace(raw: unknown): SolveClientTrace | undefined {
  if (raw === undefined || raw === null || raw === "") {
    return undefined;
  }

  if (typeof raw === "string") {
    return clientTraceSchema.parse(JSON.parse(raw));
  }

  return clientTraceSchema.parse(raw);
}

function buildTraceLogger(payload: SolveProblemPayload, imageBytes: number) {
  const recognizedText = payload.recognizedText || "";
  const questionHint = payload.questionHint || "";
  const imageHash = crypto.createHash("sha256").update(payload.imageBase64.slice(0, 8192)).digest("hex");

  return new TraceLogger({
    sessionId: payload.sessionId,
    subject: payload.subject,
    gradeBand: payload.gradeBand,
    answerStyle: payload.answerStyle,
    questionHint,
    questionHintLength: questionHint.length,
    recognizedText,
    recognizedTextPreview: recognizedText.slice(0, 800),
    recognizedTextLength: recognizedText.length,
    recognizedLineCount: recognizedText ? recognizedText.split(/\r?\n/).filter(Boolean).length : 0,
    hasImage: Boolean(payload.imageBase64),
    imageBytes,
    imageHash,
    clientTrace: payload.clientTrace || null
  });
}

function buildResponse(
  execution: SolveProblemExecution,
  traceId: string,
  sessionId: string,
  sessionSummary: string,
  turnCount: number,
  processingMs: number
): AnalyzeSolveResponse {
  return {
    ...execution.result,
    traceId,
    sessionId,
    sessionSummary,
    turnCount,
    pipelineRoute: execution.pipelineRoute,
    usedModel: execution.usedModel,
    processingMs
  };
}

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    model: config.model,
    fallbackModel: config.fallbackModel,
    port: config.port,
    reasoningEffort: config.modelReasoningEffort,
    timeoutMs: config.modelTimeoutMs,
    visionImageDetail: config.visionImageDetail
  });
});

app.get("/api/debug/traces", async (req, res) => {
  try {
    const limit = Number(req.query.limit || 30);
    const traces = await listTraces(Number.isFinite(limit) ? limit : 30);
    res.json({ items: traces });
  } catch (error) {
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.get("/api/debug/summary", async (req, res) => {
  try {
    const limit = Number(req.query.limit || 200);
    const summary = await summarizeTraces(Number.isFinite(limit) ? limit : 200);
    res.json(summary);
  } catch (error) {
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.get("/api/debug/overview", async (req, res) => {
  try {
    const limit = Number(req.query.limit || 200);
    const summary = await summarizeTraces(Number.isFinite(limit) ? limit : 200);
    res.json(summary);
  } catch (error) {
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.get("/api/debug/events", (req, res) => {
  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.flushHeaders?.();

  const sendEvent = (event: string, data: unknown) => {
    res.write(`event: ${event}\n`);
    res.write(`data: ${JSON.stringify(data)}\n\n`);
  };

  sendEvent("connected", { ok: true, at: new Date().toISOString() });

  const unsubscribe = subscribeTraceEvents((event) => {
    sendEvent("trace_updated", event);
  });

  const heartbeat = setInterval(() => {
    sendEvent("heartbeat", { at: new Date().toISOString() });
  }, 15000);

  req.on("close", () => {
    clearInterval(heartbeat);
    unsubscribe();
    res.end();
  });
});

app.get("/api/debug/traces/:traceId", async (req, res) => {
  try {
    const trace = await getTrace(req.params.traceId);
    if (!trace) {
      res.status(404).json({ error: "Trace not found" });
      return;
    }

    res.json(trace);
  } catch (error) {
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.post("/api/detect-question", async (req, res) => {
  try {
    const payload = detectQuestionSchema.parse(req.body);
    const result = await detectQuestionCrop(payload.imageBase64, payload.focusRect);

    if (!result) {
      res.status(503).json({
        error: "Layout detection service is not configured"
      });
      return;
    }

    res.json(result);
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: error.flatten() });
      return;
    }

    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.post("/api/solve", async (req, res) => {
  let traceLogger: TraceLogger | undefined;

  try {
    const payload = solveSchema.parse(req.body) as SolveProblemPayload;
    traceLogger = buildTraceLogger(payload, Math.floor((payload.imageBase64.length * 3) / 4));
    traceLogger.step("request_received", {
      entrypoint: "json",
      clientSource: payload.clientTrace?.source || "unknown",
      recognizedTextLength: payload.recognizedText?.length || 0,
      imageBytes: Math.floor((payload.imageBase64.length * 3) / 4)
    });
    const startedAt = Date.now();
    const session = getOrCreateSession(payload);
    const prior = getSessionSummary(session.id);
    const execution = await solveProblem({ ...payload, sessionId: session.id }, prior.summary, traceLogger);
    appendTurn(session.id, payload, execution.result);
    const summary = getSessionSummary(session.id);
    const response = buildResponse(
      execution,
      traceLogger.traceId,
      session.id,
      summary.summary,
      summary.turnCount,
      Date.now() - startedAt
    );

    res.setHeader("x-trace-id", traceLogger.traceId);
    await traceLogger.finalizeSuccess({
      ...response,
      pipelineRoute: execution.pipelineRoute,
      usedModel: execution.usedModel
    });
    console.log(
      JSON.stringify({
        event: "solve_completed",
        traceId: traceLogger.traceId,
        route: execution.pipelineRoute,
        model: execution.usedModel,
        processingMs: response.processingMs,
        traceFile: traceLogger.filePath
      })
    );
    res.json(response);
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: error.flatten() });
      return;
    }

    if (traceLogger) {
      await traceLogger.finalizeError(error);
      console.error(
        JSON.stringify({
          event: "solve_failed",
          traceId: traceLogger.traceId,
          traceFile: traceLogger.filePath,
          message: error instanceof Error ? error.message : String(error)
        })
      );
    }

    console.error(error);
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.post("/api/solve/upload", upload.single("image"), async (req, res) => {
  let traceLogger: TraceLogger | undefined;

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
      imageBase64: req.file.buffer.toString("base64"),
      clientTrace: parseClientTrace(req.body.clientTrace)
    };

    traceLogger = buildTraceLogger(payload, req.file.size);
    traceLogger.step("request_received", {
      entrypoint: "multipart_upload",
      clientSource: payload.clientTrace?.source || "unknown",
      recognizedTextLength: payload.recognizedText?.length || 0,
      imageBytes: req.file.size
    });
    const startedAt = Date.now();
    const session = getOrCreateSession(payload);
    const prior = getSessionSummary(session.id);
    const execution = await solveProblem({ ...payload, sessionId: session.id }, prior.summary, traceLogger);
    appendTurn(session.id, payload, execution.result);
    const summary = getSessionSummary(session.id);
    const response = buildResponse(
      execution,
      traceLogger.traceId,
      session.id,
      summary.summary,
      summary.turnCount,
      Date.now() - startedAt
    );

    res.setHeader("x-trace-id", traceLogger.traceId);
    await traceLogger.finalizeSuccess({
      ...response,
      pipelineRoute: execution.pipelineRoute,
      usedModel: execution.usedModel
    });
    console.log(
      JSON.stringify({
        event: "solve_completed",
        traceId: traceLogger.traceId,
        route: execution.pipelineRoute,
        model: execution.usedModel,
        processingMs: response.processingMs,
        traceFile: traceLogger.filePath
      })
    );
    res.json(response);
  } catch (error) {
    if (error instanceof z.ZodError) {
      res.status(400).json({ error: error.flatten() });
      return;
    }

    if (traceLogger) {
      await traceLogger.finalizeError(error);
      console.error(
        JSON.stringify({
          event: "solve_failed",
          traceId: traceLogger.traceId,
          traceFile: traceLogger.filePath,
          message: error instanceof Error ? error.message : String(error)
        })
      );
    }

    console.error(error);
    res.status(500).json({
      error: error instanceof Error ? error.message : "Unknown error"
    });
  }
});

app.listen(config.port, "0.0.0.0", () => {
  console.log(`test-evowit backend listening on ${config.port}`);
});
