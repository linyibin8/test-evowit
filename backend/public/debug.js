function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function prettyJson(value) {
  return escapeHtml(JSON.stringify(value, null, 2));
}

function renderTraceList(items) {
  const container = document.getElementById("trace-list");

  if (!items || items.length === 0) {
    container.innerHTML = `<p class="placeholder">还没有 trace 记录。</p>`;
    return;
  }

  container.innerHTML = items
    .map(
      (item) => `
        <button class="trace-item" data-trace-id="${escapeHtml(item.traceId)}" type="button">
          <strong>${escapeHtml(item.traceId)}</strong>
          <span>${escapeHtml(item.pipelineRoute || "pending")} / ${escapeHtml(item.usedModel || "pending")}</span>
          <small>${escapeHtml(item.subject || "")} · ${escapeHtml(item.gradeBand || "")}</small>
          <small>${escapeHtml(item.startedAt || "")}</small>
        </button>
      `
    )
    .join("");

  container.querySelectorAll("[data-trace-id]").forEach((button) => {
    button.addEventListener("click", () => {
      loadTrace(button.getAttribute("data-trace-id"));
    });
  });
}

function renderTraceDetail(trace) {
  const container = document.getElementById("trace-detail");
  const routing = trace.routing || {};
  const prompt = trace.prompt || {};

  container.innerHTML = `
    <article class="result-card">
      <h2>Trace ${escapeHtml(trace.traceId)}</h2>
      <div class="meta-strip">
        <span>状态：<strong>${escapeHtml(trace.status)}</strong></span>
        <span>开始：<strong>${escapeHtml(trace.startedAt)}</strong></span>
        <span>结束：<strong>${escapeHtml(trace.finishedAt || "running")}</strong></span>
      </div>

      <section class="info-block">
        <h3>请求概要</h3>
        <pre>${prettyJson(trace.request)}</pre>
      </section>

      <section class="info-block">
        <h3>路由决策</h3>
        <pre>${prettyJson(routing)}</pre>
      </section>

      <section class="info-block">
        <h3>系统提示词</h3>
        <pre>${escapeHtml(prompt.systemPrompt || "")}</pre>
      </section>

      <section class="info-block">
        <h3>提交给模型的上下文</h3>
        <pre>${escapeHtml(prompt.userPrompt || "")}</pre>
      </section>

      <section class="info-block">
        <h3>模型调用记录</h3>
        <pre>${prettyJson(trace.modelAttempts || [])}</pre>
      </section>

      <section class="info-block">
        <h3>处理步骤</h3>
        <pre>${prettyJson(trace.steps || [])}</pre>
      </section>

      <section class="info-block">
        <h3>最终结果</h3>
        <pre>${prettyJson(trace.result || null)}</pre>
      </section>

      ${
        trace.error
          ? `
      <section class="info-block">
        <h3>错误信息</h3>
        <pre>${prettyJson(trace.error)}</pre>
      </section>
      `
          : ""
      }
    </article>
  `;
}

async function loadTrace(traceId) {
  const response = await fetch(`/api/debug/traces/${traceId}`);
  const data = await response.json();

  if (!response.ok) {
    document.getElementById("trace-detail").innerHTML = `<p class="error">${escapeHtml(data.error || "加载 trace 失败。")}</p>`;
    return;
  }

  renderTraceDetail(data);
}

async function loadTraceList() {
  const response = await fetch("/api/debug/traces?limit=40");
  const data = await response.json();

  if (!response.ok) {
    document.getElementById("trace-list").innerHTML = `<p class="error">${escapeHtml(data.error || "加载 trace 列表失败。")}</p>`;
    return;
  }

  renderTraceList(data.items || []);
  if (data.items && data.items.length > 0) {
    loadTrace(data.items[0].traceId);
  }
}

loadTraceList();
