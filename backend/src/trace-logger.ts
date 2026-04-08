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

export interface TraceListItem {
  traceId: string;
  status: "running" | "ok" | "error";
  startedAt: string;
  finishedAt?: string;
  updatedAt: string;
  subject?: unknown;
  gradeBand?: unknown;
  pipelineRoute?: unknown;
  selectedRoute?: unknown;
  usedModel?: unknown;
  processingMs?: unknown;
  recognizedTextLength?: unknown;
  recognizedLineCount?: unknown;
  clientSource?: unknown;
  ocrQuality?: unknown;
  ocrPass?: unknown;
  autoCropApplied?: unknown;
  lastStepName?: string;
  errorMessage?: string;
}

interface TraceStreamEvent {
  type: "trace_updated";
  item: TraceListItem;
}

const tracesRoot = path.join(config.logDir, "traces");
const subscribers = new Set<(event: TraceStreamEvent) => void>();

function dayBucket(isoTime: string) {
  return isoTime.slice(0, 10);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function cloneRecord<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
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

async function readTraceRecord(filePath: string) {
  const content = await fs.readFile(filePath, "utf8");
  return JSON.parse(content) as TraceRecord;
}

function incrementCounter(store: Record<string, number>, key: string | undefined) {
  if (!key) {
    return;
  }

  store[key] = (store[key] || 0) + 1;
}

function buildTraceListItem(record: TraceRecord, updatedAt = new Date().toISOString()): TraceListItem {
  const clientTrace = isObject(record.request.clientTrace) ? record.request.clientTrace : {};
  const lastStep = record.steps[record.steps.length - 1];

  return {
    traceId: record.traceId,
    status: record.status,
    startedAt: record.startedAt,
    finishedAt: record.finishedAt,
    updatedAt,
    subject: record.request.subject,
    gradeBand: record.request.gradeBand,
    pipelineRoute: record.result?.pipelineRoute,
    selectedRoute: record.routing?.selectedRoute,
    usedModel: record.result?.usedModel,
    processingMs: record.result?.processingMs,
    recognizedTextLength: record.request.recognizedTextLength,
    recognizedLineCount: record.request.recognizedLineCount,
    clientSource: clientTrace.source,
    ocrQuality: clientTrace.ocrQuality,
    ocrPass: clientTrace.ocrPass,
    autoCropApplied: clientTrace.autoCropApplied,
    lastStepName: lastStep?.name,
    errorMessage: record.error?.message
  };
}

function emitTraceEvent(record: TraceRecord) {
  const event: TraceStreamEvent = {
    type: "trace_updated",
    item: buildTraceListItem(record)
  };

  for (const subscriber of subscribers) {
    try {
      subscriber(event);
    } catch (error) {
      console.error("trace_event_subscriber_failed", error);
    }
  }
}

export class TraceLogger {
  readonly traceId: string;
  readonly filePath: string;

  private readonly record: TraceRecord;
  private flushChain = Promise.resolve();

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

    this.queueFlush();
  }

  step(name: string, data?: unknown) {
    this.record.steps.push({
      at: new Date().toISOString(),
      name,
      data
    });
    this.queueFlush();
  }

  setPrompt(systemPrompt: string, userPrompt: string) {
    this.record.prompt = {
      systemPrompt,
      userPrompt
    };
    this.queueFlush();
  }

  setRouting(routing: Record<string, unknown>) {
    this.record.routing = routing;
    this.queueFlush();
  }

  addModelAttempt(attempt: Record<string, unknown>) {
    this.record.modelAttempts.push({
      at: new Date().toISOString(),
      ...attempt
    });
    this.queueFlush();
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

  private queueFlush() {
    const snapshot = cloneRecord(this.record);
    this.flushChain = this.flushChain
      .then(async () => {
        await ensureDir(path.dirname(this.filePath));
        await fs.writeFile(this.filePath, JSON.stringify(snapshot, null, 2), "utf8");
        emitTraceEvent(snapshot);
      })
      .catch((error) => {
        console.error("trace_flush_failed", error);
      });
  }

  private async flush() {
    this.queueFlush();
    await this.flushChain;
  }
}

export function subscribeTraceEvents(listener: (event: TraceStreamEvent) => void) {
  subscribers.add(listener);
  return () => {
    subscribers.delete(listener);
  };
}

export async function getTrace(traceId: string) {
  const traceFile = await findTraceFile(traceId);
  if (!traceFile) {
    return null;
  }

  return readTraceRecord(traceFile);
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

  return Promise.all(
    latest.map(async ({ filePath, stat }) => {
      const parsed = await readTraceRecord(filePath);
      return buildTraceListItem(parsed, new Date(stat.mtimeMs).toISOString());
    })
  );
}

export async function summarizeTraces(limit = 200) {
  const items = await listTraces(limit);
  const routes: Record<string, number> = {};
  const models: Record<string, number> = {};
  const subjects: Record<string, number> = {};
  const statuses: Record<string, number> = {};
  const ocrQualities: Record<string, number> = {};
  const sources: Record<string, number> = {};

  let processingTotal = 0;
  let processingCount = 0;
  let fallbackCount = 0;

  for (const item of items) {
    incrementCounter(routes, String(item.pipelineRoute || item.selectedRoute || "pending"));
    incrementCounter(models, String(item.usedModel || "pending"));
    incrementCounter(subjects, String(item.subject || "unknown"));
    incrementCounter(statuses, String(item.status || "unknown"));
    incrementCounter(ocrQualities, String(item.ocrQuality || "unknown"));
    incrementCounter(sources, String(item.clientSource || "unknown"));

    if (item.pipelineRoute === "heuristic_fallback") {
      fallbackCount += 1;
    }

    if (typeof item.processingMs === "number") {
      processingTotal += item.processingMs;
      processingCount += 1;
    }
  }

  return {
    total: items.length,
    running: statuses.running || 0,
    ok: statuses.ok || 0,
    error: statuses.error || 0,
    fallbackCount,
    averageProcessingMs: processingCount > 0 ? Math.round(processingTotal / processingCount) : 0,
    routes,
    models,
    subjects,
    ocrQualities,
    sources
  };
}
