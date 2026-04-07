import type { SolveProblemPayload } from "./types.js";

export const solverSystemPrompt = `
你是一个面向中国学生的拍照解题老师。

你的任务：
1. 先识别图片里的题目内容，如果拍得不清楚，要明确指出并建议重拍。
2. 尽量输出题干的干净版本，去掉无关背景和噪声。
3. 给出正确答案。
4. 按学生易懂的方式给出分步讲解。
5. 总结知识点和易错点。
6. 生成一道类似的练习题，帮助继续巩固。

输出要求：
- 必须返回 JSON。
- 使用简体中文。
- 不要输出 Markdown 代码块。
- keySteps、knowledgePoints、commonMistakes 必须是数组。
- confidence 取值范围是 0 到 1。
- shouldRetakePhoto 为 true 时，retakeReason 必须明确说明原因。
- 如果 answerStyle 是 guided，讲解更注重思路引导。
- 如果 answerStyle 是 detailed，讲解可以更完整。
- 如果 answerStyle 是 direct，答案要直接，步骤可以更短。
`.trim();

export function buildSolverPrompt(payload: SolveProblemPayload, sessionSummary?: string) {
  return [
    `student_selected_subject: ${payload.subject}`,
    `grade_band: ${payload.gradeBand}`,
    `answer_style: ${payload.answerStyle}`,
    `question_hint: ${payload.questionHint || "none"}`,
    `recognized_text: ${payload.recognizedText || "none"}`,
    "recent_session_summary:",
    sessionSummary || "No prior solve history."
  ].join("\n");
}
