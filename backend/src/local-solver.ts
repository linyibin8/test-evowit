import type { SolveProblemPayload, SolveProblemResult } from "./types.js";

interface LinearExpression {
  coefficient: number;
  constant: number;
}

function normalizeText(text: string) {
  return text
    .replace(/[，。；：]/g, " ")
    .replace(/[＝]/g, "=")
    .replace(/[×xX]/g, "x")
    .replace(/[﹣−]/g, "-")
    .replace(/[÷]/g, "/")
    .replace(/[？?]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function extractQuestionText(payload: SolveProblemPayload) {
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
    .split(/\n|。|；|;/)
    .map((line) => normalizeText(line))
    .filter(Boolean);

  return (
    lines.find((line) => /[0-9x=+\-*/()]/.test(line)) ||
    normalized
  );
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
      } else if (raw === "-") {
        coefficient -= 1;
      } else {
        const value = Number(raw);
        if (Number.isNaN(value)) {
          return null;
        }
        coefficient += value;
      }
    } else {
      const value = Number(piece);
      if (Number.isNaN(value)) {
        return null;
      }
      constant += value;
    }
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
  const cleanAnswer = Number.isInteger(answer) ? `${answer}` : answer.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");

  return {
    problemText: match,
    cleanedQuestion: match,
    inferredSubject: "数学",
    problemType: "一元一次方程",
    difficulty: "基础",
    answer: `x = ${cleanAnswer}`,
    keySteps: [
      `原式：${match}`,
      `把常数项移到等号右边，得到 ${left.coefficient}x = ${constant}`,
      `两边同时除以 ${coefficient}，得到 x = ${cleanAnswer}`
    ],
    fullExplanation: `这是一道一元一次方程。先把左边的常数项移到右边，再把 x 前面的系数化成 1，所以最终得到 x = ${cleanAnswer}。`,
    knowledgePoints: ["等式两边同时进行相同运算", "移项", "化简一元一次方程"],
    commonMistakes: ["移项时忘记变号", "最后一步没有同时除以 x 的系数"],
    followUpPractice: `请继续练习：3x - 7 = 11，求 x。`,
    encouragement: "你已经抓住这类题的核心了，下一步就是多练几道移项题。",
    confidence: 0.79,
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

  const answer = Number.isInteger(value) ? `${value}` : value.toFixed(4).replace(/0+$/, "").replace(/\.$/, "");

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
    fullExplanation: `根据运算顺序，这道题可以逐步化简，最后得到结果 ${answer}。`,
    knowledgePoints: ["四则运算顺序", "括号优先"],
    commonMistakes: ["没有先算乘除", "括号里的内容漏算"],
    followUpPractice: `请继续练习：18 ÷ 3 + 4 × 2 = ?`,
    encouragement: "基础运算做得越稳，后面的综合题就越轻松。",
    confidence: 0.72,
    shouldRetakePhoto: false,
    retakeReason: ""
  };
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
      fullExplanation: "当前图片没有拿到足够清晰的文字信息，建议补充手动题干，或重新拍一张更清晰的照片。",
      knowledgePoints: [],
      commonMistakes: [],
      followUpPractice: "",
      encouragement: "把题目拍清楚之后，我们再继续。",
      confidence: 0.2,
      shouldRetakePhoto: true,
      retakeReason: "未检测到可用题干，请补充手动题干或重拍。"
    };
  }

  if (payload.subject === "math" || payload.subject === "general") {
    const linear = solveLinearEquation(questionText);
    if (linear) {
      return linear;
    }

    const arithmetic = solveArithmetic(questionText);
    if (arithmetic) {
      return arithmetic;
    }
  }

  return {
    problemText: questionText,
    cleanedQuestion: questionText,
    inferredSubject: payload.subject === "math" ? "数学" : "通用",
    problemType: "待进一步识别",
    difficulty: "未知",
    answer: "当前离线备援只稳定支持基础数学题。",
    keySteps: [
      "已经提取到题干文本。",
      "但当前模型服务不可用，离线备援暂时只能稳定支持基础算式和一元一次方程。"
    ],
    fullExplanation: "如果这是语文、英语、科学或更复杂的数学题，需要等在线模型恢复后再给出更完整解析。",
    knowledgePoints: ["题干识别", "离线备援"],
    commonMistakes: ["题目照片过斜", "手动题干没有写完整"],
    followUpPractice: "可以先补充完整题干，再重新解析。",
    encouragement: "主模型恢复后，这类题也可以继续补上完整讲解。",
    confidence: 0.42,
    shouldRetakePhoto: false,
    retakeReason: ""
  };
}
