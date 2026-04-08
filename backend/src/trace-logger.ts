import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { config } from "./config.js";

interface TraceStep {
  at: string;
  name: string;
  data?: unknown;
}

interface TraceRecord {
  traceId: string;
  status: "running" | "ok" | "error";
  startedAt: string;
  finishedAt?: string;
  request: Record<string, unknown>;
  prompt?: {
    systemPrompt: string;
    userPrompt: string;
  };
  routing?: Record<string, unknown>;
  modelAttempts: Array<Record<string, unknown>>;
  steps: TraceStep[];
  result?: Record<string, unknown>;
  error?: {
    message: string;
    stack?: string;
  };
}

const tracesRoot = path.join(config.logDir, "traces");

function dayBucket(isoTime: string) {
  return isoTime.slice(0, 10);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function ensureDir(dirPath: string) {
  await fs.mkdir(dirPath, { recursive: true });
}

async function listTraceFiles(rootDir: string) {
  try {
    const dayDirs = await fs.readdir(rootDir, { withFileTypes: true });
    const files: string[] = [];

    for (const entry of dayDirs) {
      if (!entry.isDirectory()) {
        continue;
      }

      const fullDir = path.join(rootDir, entry.name);
      const dayFiles = await fs.readdir(fullDir, { withFileTypes: true });
      for (const fileEntry of dayFiles) {
        if (fileEntry.isFile() && fileEntry.name.endsWith(".json")) {
          files.push(path.join(fullDir, fileEntry.name));
        }
      }
    }

    return files;
  } catch (error) {
    if (isObject(error) && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

async function findTraceFile(traceId: string) {
  const files = await listTraceFiles(tracesRoot);
  return files.find((file) => path.basename(file, ".json") === traceId) || null;
}

export class TraceLogger {
  readonly traceId: string;
  readonly filePath: string;

  private readonly record: TraceRecord;

  constructor(request: Record<string, unknown>) {
    const startedAt = new Date().toISOString();
    const traceId = crypto.randomUUID();
    const dir = path.join(tracesRoot, dayBucket(startedAt));

    this.traceId = traceId;
    this.filePath = path.join(dir, `${traceId}.json`);
    this.record = {
      traceId,
      status: "running",
      startedAt,
      request,
      modelAttempts: [],
      steps: []
    };
  }

  step(name: string, data?: unknown) {
    this.record.steps.push({
      at: new Date().toISOString(),
      name,
      data
    });
  }

  setPrompt(systemPrompt: string, userPrompt: string) {
    this.record.prompt = {
      systemPrompt,
      userPrompt
    };
  }

  setRouting(routing: Record<string, unknown>) {
    this.record.routing = routing;
  }

  addModelAttempt(attempt: Record<string, unknown>) {
    this.record.modelAttempts.push({
      at: new Date().toISOString(),
      ...attempt
    });
  }

  async finalizeSuccess(result: Record<string, unknown>) {
    this.record.status = "ok";
    this.record.finishedAt = new Date().toISOString();
    this.record.result = result;
    await this.flush();
  }

  async finalizeError(error: unknown) {
    this.record.status = "error";
    this.record.finishedAt = new Date().toISOString();
    this.record.error = {
      message: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack : undefined
    };
    await this.flush();
  }

  private async flush() {
    await ensureDir(path.dirname(this.filePath));
    await fs.writeFile(this.filePath, JSON.stringify(this.record, null, 2), "utf8");
  }
}

export async function getTrace(traceId: string) {
  const traceFile = await findTraceFile(traceId);
  if (!traceFile) {
    return null;
  }

  const content = await fs.readFile(traceFile, "utf8");
  return JSON.parse(content);
}

export async function listTraces(limit = 30) {
  const files = await listTraceFiles(tracesRoot);
  const stats = await Promise.all(
    files.map(async (filePath) => ({
      filePath,
      stat: await fs.stat(filePath)
    }))
  );

  const latest = stats
    .sort((left, right) => right.stat.mtimeMs - left.stat.mtimeMs)
    .slice(0, limit);

  const items = await Promise.all(
    latest.map(async ({ filePath, stat }) => {
      const content = await fs.readFile(filePath, "utf8");
      const parsed = JSON.parse(content) as TraceRecord;
      return {
        traceId: parsed.traceId,
        status: parsed.status,
        startedAt: parsed.startedAt,
        finishedAt: parsed.finishedAt,
        updatedAt: new Date(stat.mtimeMs).toISOString(),
        subject: parsed.request.subject,
        gradeBand: parsed.request.gradeBand,
        pipelineRoute: parsed.result?.pipelineRoute,
        usedModel: parsed.result?.usedModel,
        processingMs: parsed.result?.processingMs,
        recognizedTextLength: parsed.request.recognizedTextLength
      };
    })
  );

  return items;
}
