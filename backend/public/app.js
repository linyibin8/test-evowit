function renderChips(items) {
  if (!items || items.length === 0) {
    return "<span>暂无</span>";
  }

  return items.map((item) => `<span>${item}</span>`).join("");
}

function renderSteps(items) {
  if (!items || items.length === 0) {
    return "<p>暂无步骤。</p>";
  }

  return `<ol>${items.map((item) => `<li>${item}</li>`).join("")}</ol>`;
}

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function renderResult(data) {
  const result = document.getElementById("result");
  result.innerHTML = `
    <article class="result-card">
      <h2>${data.shouldRetakePhoto ? "建议重拍后再试" : "解析完成"}</h2>
      <div class="meta-strip">
        <span>Trace ID：<strong>${escapeHtml(data.traceId)}</strong></span>
        <span>路由：<strong>${escapeHtml(data.pipelineRoute)}</strong></span>
        <span>模型：<strong>${escapeHtml(data.usedModel)}</strong></span>
        <span>耗时：<strong>${escapeHtml(data.processingMs)} ms</strong></span>
      </div>

      <div class="grid">
        <section class="info-block">
          <h3>识别到的题目</h3>
          <pre>${escapeHtml(data.problemText)}</pre>
        </section>
        <section class="info-block">
          <h3>清洗后的题干</h3>
          <pre>${escapeHtml(data.cleanedQuestion)}</pre>
        </section>
        <section class="info-block">
          <h3>答案</h3>
          <pre>${escapeHtml(data.answer)}</pre>
        </section>
        <section class="info-block">
          <h3>题型 / 难度</h3>
          <p>${escapeHtml(data.problemType)}</p>
          <p>${escapeHtml(data.difficulty)}</p>
          <p>置信度：${Math.round((data.confidence || 0) * 100)}%</p>
        </section>
      </div>

      <section class="info-block">
        <h3>分步讲解</h3>
        ${renderSteps(data.keySteps)}
      </section>

      <section class="info-block">
        <h3>完整解析</h3>
        <pre>${escapeHtml(data.fullExplanation)}</pre>
      </section>

      <section class="info-block">
        <h3>知识点</h3>
        <div class="chips">${renderChips(data.knowledgePoints)}</div>
      </section>

      <section class="info-block">
        <h3>易错点</h3>
        <div class="chips">${renderChips(data.commonMistakes)}</div>
      </section>

      <section class="info-block">
        <h3>继续练习</h3>
        <pre>${escapeHtml(data.followUpPractice)}</pre>
      </section>

      <section class="info-block">
        <h3>鼓励语</h3>
        <pre>${escapeHtml(data.encouragement)}</pre>
      </section>

      ${data.shouldRetakePhoto ? `
      <section class="info-block">
        <h3>重拍建议</h3>
        <pre>${escapeHtml(data.retakeReason)}</pre>
      </section>
      ` : ""}

      <section class="info-block">
        <h3>最近会话摘要</h3>
        <pre>${escapeHtml(data.sessionSummary)}</pre>
      </section>
    </article>
  `;
}

document.getElementById("solver-form").addEventListener("submit", async (event) => {
  event.preventDefault();

  const result = document.getElementById("result");
  result.innerHTML = `<p class="placeholder">正在识题和解析，请稍候...</p>`;

  const formData = new FormData();
  formData.append("subject", document.getElementById("subject").value);
  formData.append("gradeBand", document.getElementById("gradeBand").value);
  formData.append("answerStyle", document.getElementById("answerStyle").value);
  formData.append("questionHint", document.getElementById("questionHint").value);
  formData.append("recognizedText", document.getElementById("recognizedText").value);
  formData.append("image", document.getElementById("imageInput").files[0]);

  const response = await fetch("/api/solve/upload", {
    method: "POST",
    body: formData
  });

  const data = await response.json();
  if (!response.ok) {
    result.innerHTML = `<p class="error">${escapeHtml(data.error || "请求失败。")}</p>`;
    return;
  }

  renderResult(data);
});
