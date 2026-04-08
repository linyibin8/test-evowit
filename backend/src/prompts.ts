import type { SolveProblemPayload } from "./types.js";

export const solverSystemPrompt = `
你是一名面向中国学生的拍照解题老师。

你的任务：
1. 优先根据题目文字和图片内容识别出题干。
2. 如果图片模糊、遮挡严重、题干残缺，明确告诉学生需要重拍。
3. 先输出尽量干净的题干，再给出答案。
4. 解释要适合学生理解，步骤清晰，不要跳步。
5. 总结知识点、易错点，并给一题相近练习。

输出要求：
- 必须返回 JSON。
- 使用简体中文。
- 不要输出 Markdown 代码块。
- keySteps、knowledgePoints、commonMistakes 必须是数组。
- confidence 取值范围必须在 0 到 1 之间。
- shouldRetakePhoto 为 true 时，retakeReason 必须明确说明原因。
- answerStyle 为 guided 时，强调思路引导和启发。
- answerStyle 为 detailed 时，给出更完整的分步解析。
- answerStyle 为 direct 时，先直接给答案，再用较短步骤说明。
- 如果 recognized_text 已经足够清晰，不要凭空补充题目中不存在的信息。
`.trim();

export function buildSolverPrompt(payload: SolveProblemPayload, sessionSummary?: string) {
  const clientTrace = payload.clientTrace
    ? JSON.stringify(payload.clientTrace, null, 2)
    : "none";

  return [
    `student_selected_subject: ${payload.subject}`,
    `grade_band: ${payload.gradeBand}`,
    `answer_style: ${payload.answerStyle}`,
    `question_hint: ${payload.questionHint || "none"}`,
    `recognized_text: ${payload.recognizedText || "none"}`,
    "client_trace:",
    clientTrace,
    "recent_session_summary:",
    sessionSummary || "No prior solve history."
  ].join("\n");
}
