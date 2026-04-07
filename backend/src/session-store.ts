import crypto from "node:crypto";
import type { SessionTurn, SolveProblemPayload, SolveProblemResult } from "./types.js";

interface SessionState {
  id: string;
  createdAt: string;
  updatedAt: string;
  subject: SolveProblemPayload["subject"];
  gradeBand: string;
  turns: SessionTurn[];
}

const sessions = new Map<string, SessionState>();

export function getOrCreateSession(payload: SolveProblemPayload) {
  const id = payload.sessionId || crypto.randomUUID();
  const existing = sessions.get(id);
  if (existing) {
    existing.updatedAt = new Date().toISOString();
    existing.subject = payload.subject;
    existing.gradeBand = payload.gradeBand;
    return existing;
  }

  const created: SessionState = {
    id,
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    subject: payload.subject,
    gradeBand: payload.gradeBand,
    turns: []
  };
  sessions.set(id, created);
  return created;
}

export function appendTurn(sessionId: string, payload: SolveProblemPayload, result: SolveProblemResult) {
  const state = sessions.get(sessionId);
  if (!state) {
    return;
  }

  state.turns.push({
    at: new Date().toISOString(),
    question: result.cleanedQuestion || result.problemText,
    answer: result.answer,
    subject: result.inferredSubject || payload.subject
  });
  state.updatedAt = new Date().toISOString();
}

export function getSessionSummary(sessionId: string) {
  const state = sessions.get(sessionId);
  if (!state || state.turns.length === 0) {
    return {
      summary: "No prior solve history.",
      turnCount: 0
    };
  }

  const summary = state.turns
    .slice(-3)
    .map((turn, index) => {
      const question = turn.question.replace(/\s+/g, " ").slice(0, 60);
      const answer = turn.answer.replace(/\s+/g, " ").slice(0, 60);
      return `Turn ${index + 1}: subject=${turn.subject}; question=${question}; answer=${answer}`;
    })
    .join("\n");

  return {
    summary,
    turnCount: state.turns.length
  };
}

