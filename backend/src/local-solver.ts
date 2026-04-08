import type { SolveProblemPayload, SolveProblemResult } from "./types.js";

interface LinearExpression {
  coefficient: number;
  constant: number;
}

export function normalizeText(text: string) {
  return text
    .replace(/[，。；：]/g, " ")
    .replace(/[＝﹦]/g, "=")
    .replace(/[脳xX×]/g, "x")
    .replace(/[÷]/g, "/")
    .replace(/[（]/g, "(")
    .replace(/[）]/g, ")")
    .replace(/[＋]/g, "+")
    .replace(/[－—–]/g, "-")
    .replace(/[？]/g, "")
    .replace(/\r/g, "\n")
    .replace(/[^\S\n]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

export function extractQuestionText(payload: SolveProblemPayload) {
  return normalizeText(payload.recognizedText || payload.questionHint || "");
}

function pickMathCore(text: string) {
  const normalized = normalizeText(text);
  const equationMatch = normalized.match(/[-+*/().0-9x\s]+=[-+*/().0-9x\s]+/);
  if (equationMatch) {
    return normalizeText(equationMatch[0]);
  }

  const arithmeticMatch = normalized.match(/[0-9().+\-*/\s]{3,}/);
  if (arithmeticMatch) {
    return normalizeText(arithmeticMatch[0]);
  }

  const lines = normalized
    .split(/\n|;/)
    .map((line) => normalizeText(line))
    .filter(Boolean);

  return lines.find((line) => /[0-9x=+\-*/()]/.test(line)) || normalized;
}

function trimNumber(value: number) {
  return Number.isInteger(value) ? String(value) : value.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");
}

function parseLinearExpression(input: string): LinearExpression | null {
  const sanitized = input.replace(/\s+/g, "").replace(/-/g, "+-");
  const pieces = sanitized.split("+").filter(Boolean);
  if (pieces.length === 0) {
    return null;
  }

  let coefficient = 0;
  let constant = 0;

  for (const piece of pieces) {
    if (piece.includes("x")) {
      const raw = piece.replace(/\*/g, "").replace("x", "");
      if (raw === "" || raw === "+") {
        coefficient += 1;
        continue;
      }
      if (raw === "-") {
        coefficient -= 1;
        continue;
      }

      const value = Number(raw);
      if (Number.isNaN(value)) {
        return null;
      }
      coefficient += value;
      continue;
    }

    const value = Number(piece);
    if (Number.isNaN(value)) {
      return null;
    }
    constant += value;
  }

  return { coefficient, constant };
}

function solveLinearEquation(text: string): SolveProblemResult | null {
  const match = pickMathCore(text);
  if (!match.includes("=") || !match.includes("x")) {
    return null;
  }

  const [leftRaw, rightRaw] = match.split("=");
  const left = parseLinearExpression(leftRaw);
  const right = parseLinearExpression(rightRaw);
  if (!left || !right) {
    return null;
  }

  const coefficient = left.coefficient - right.coefficient;
  const constant = right.constant - left.constant;
  if (coefficient === 0) {
    return null;
  }

  const answer = constant / coefficient;
  const cleanAnswer = trimNumber(answer);

  return {
    problemText: match,
    cleanedQuestion: match,
    inferredSubject: "数学",
    problemType: "一元一次方程",
    difficulty: "基础",
    answer: `x = ${cleanAnswer}`,
    keySteps: [
      `原式：${match}`,
      `把含 x 的项整理到一边，把常数项整理到另一边，得到 ${coefficient}x = ${constant}`,
      `两边同时除以 ${coefficient}，得到 x = ${cleanAnswer}`
    ],
    fullExplanation: `这是一道一元一次方程。先移项，把含 x 的项放到同一边，把常数项放到另一边，再把 x 前面的系数化成 1，就能得到答案 x = ${cleanAnswer}。`,
    knowledgePoints: ["等式两边同时进行相同运算", "移项", "一元一次方程求解"],
    commonMistakes: ["移项时忘记变号", "最后没有除以 x 前面的系数"],
    followUpPractice: "继续练习：3x - 7 = 11，求 x。",
    encouragement: "你已经抓住这类题的核心了，再多做几道移项题会更熟练。",
    confidence: 0.86,
    shouldRetakePhoto: false,
    retakeReason: ""
  };
}

function solveArithmetic(text: string): SolveProblemResult | null {
  const match = pickMathCore(text);
  const expression = match
    .replace(/请解方程/g, "")
    .replace(/写出解题步骤/g, "")
    .replace(/求值/g, "")
    .replace(/求/g, "")
    .replace(/=/g, "")
    .replace(/\s+/g, "");

  if (!/^[0-9+\-*/().]+$/.test(expression) || !/[0-9]/.test(expression)) {
    return null;
  }

  let value: number;
  try {
    value = Function(`"use strict"; return (${expression});`)() as number;
  } catch {
    return null;
  }

  const answer = trimNumber(value);

  return {
    problemText: match,
    cleanedQuestion: expression,
    inferredSubject: "数学",
    problemType: "四则运算",
    difficulty: "基础",
    answer,
    keySteps: [
      `原式：${expression}`,
      "按照先乘除后加减的顺序依次计算。",
      `最终结果是 ${answer}。`
    ],
    fullExplanation: `根据运算顺序，这道题需要先处理乘除，再处理加减，最后得到结果 ${answer}。`,
    knowledgePoints: ["四则运算顺序", "括号优先"],
    commonMistakes: ["没有先算乘除", "括号里的内容漏算"],
    followUpPractice: "继续练习：8 / 4 + 3 * 2 = ?",
    encouragement: "基础运算越扎实，后面的综合题就会越轻松。",
    confidence: 0.82,
    shouldRetakePhoto: false,
    retakeReason: ""
  };
}

function buildRetakeHeuristicResult(payload: SolveProblemPayload, questionText: string): SolveProblemResult {
  return {
    problemText: questionText,
    cleanedQuestion: questionText,
    inferredSubject: payload.subject === "math" ? "数学" : "通用",
    problemType: "需要重新拍题",
    difficulty: "待识别",
    answer: "当前图片更像整页作业或题干不完整，直接作答很容易答错。",
    keySteps: [
      "已经识别到部分题干。",
      "但当前内容更像多道题混在一起，建议先裁剪到单题。"
    ],
    fullExplanation: "拍照解题最怕整页混题。先把画面裁成只保留一道题，再重新解析，模型才能更稳定地给出正确答案。",
    knowledgePoints: ["单题拍照", "OCR 识别质量"],
    commonMistakes: ["整页一起拍", "题干裁不完整", "照片歪斜或反光"],
    followUpPractice: "先裁到单题后重新识别。",
    encouragement: "你已经把题拍下来了，再裁一步，解析质量会明显更好。",
    confidence: 0.25,
    shouldRetakePhoto: true,
    retakeReason: "请裁剪到单题后重拍，或手动补充完整题干。"
  };
}

export function tryLocalSolve(payload: SolveProblemPayload): SolveProblemResult | null {
  const questionText = extractQuestionText(payload);
  if (!questionText) {
    return null;
  }

  if (payload.subject !== "math" && payload.subject !== "general") {
    return null;
  }

  return solveLinearEquation(questionText) || solveArithmetic(questionText);
}

export function solveWithHeuristics(payload: SolveProblemPayload): SolveProblemResult {
  const questionText = extractQuestionText(payload);

  if (!questionText) {
    return {
      problemText: "",
      cleanedQuestion: "",
      inferredSubject: payload.subject === "math" ? "数学" : "通用",
      problemType: "无法识别",
      difficulty: "未知",
      answer: "暂时无法识别题目内容。",
      keySteps: [],
      fullExplanation: "当前图片里没有足够清晰的题干文字，建议补充手动题干，或者重新拍一张更清晰的照片。",
      knowledgePoints: [],
      commonMistakes: [],
      followUpPractice: "",
      encouragement: "把题目拍清楚之后，我们再继续。",
      confidence: 0.2,
      shouldRetakePhoto: true,
      retakeReason: "未检测到可用题干，请补充手动题干或重新拍摄。"
    };
  }

  const localSolved = tryLocalSolve(payload);
  if (localSolved) {
    return localSolved;
  }

  const lineCount = questionText.split(/\n/).filter(Boolean).length;
  const numberedQuestionCount = (questionText.match(/(?:^|\n)\s*\d+[.)、．]/g) || []).length;
  if (lineCount >= 10 || numberedQuestionCount >= 2 || questionText.length >= 180) {
    return buildRetakeHeuristicResult(payload, questionText);
  }

  return {
    problemText: questionText,
    cleanedQuestion: questionText,
    inferredSubject: payload.subject === "math" ? "数学" : "通用",
    problemType: "待进一步识别",
    difficulty: "未知",
    answer: "当前模型服务暂时不可用，本地兜底模式还不能稳定处理这类题。",
    keySteps: [
      "已经提取到题干文字。",
      "但当前在线模型请求失败，本地兜底暂时只覆盖基础数学题。"
    ],
    fullExplanation: "如果这是语文、英语、科学或更复杂的数学题，需要在线模型恢复后才能给出完整讲解。",
    knowledgePoints: ["题干识别", "本地兜底解题"],
    commonMistakes: ["照片过斜或裁切过多", "手动补充的题干不完整"],
    followUpPractice: "可以先补充完整题干，然后重新解析。",
    encouragement: "线上链路恢复后，这类题也可以继续补上完整讲解。",
    confidence: 0.45,
    shouldRetakePhoto: false,
    retakeReason: ""
  };
}
