const state = {
  items: [],
  selectedTraceId: null,
  summary: null,
  streamStatus: "connecting",
  refreshTimer: null
};

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function prettyJson(value) {
  return escapeHtml(JSON.stringify(value, null, 2));
}

function formatNumber(value) {
  return typeof value === "number" ? value.toLocaleString("zh-CN") : "--";
}

function badge(label, tone = "default") {
  return `<span class="badge badge-${tone}">${escapeHtml(label)}</span>`;
}

function routeTone(route) {
  if (route === "local") return "success";
  if (route === "model_vision") return "accent";
  if (route === "model_text_only") return "info";
  if (route === "heuristic_fallback") return "warning";
  return "default";
}

function statusTone(status) {
  if (status === "ok") return "success";
  if (status === "running") return "accent";
  if (status === "error") return "danger";
  return "default";
}

function renderSummary(summary) {
  const container = document.getElementById("summary-cards");
  if (!summary) {
    container.innerHTML = `<article class="stat-card"><span>暂无数据</span><strong>--</strong></article>`;
    return;
  }

  const cards = [
    { label: "最近请求", value: summary.total, meta: "最近窗口内 trace 数" },
    { label: "运行中", value: summary.running, meta: "正在处理的题目" },
    { label: "平均耗时", value: `${formatNumber(summary.averageProcessingMs)} ms`, meta: "成功/兜底平均耗时" },
    { label: "兜底次数", value: summary.fallbackCount, meta: "落到本地兜底或重拍提示" }
  ];

  container.innerHTML = cards
    .map(
      (card) => `
        <article class="stat-card">
          <span>${escapeHtml(card.label)}</span>
          <strong>${escapeHtml(card.value)}</strong>
          <small>${escapeHtml(card.meta)}</small>
        </article>
      `
    )
    .join("");
}

function getFilteredItems() {
  const search = document.getElementById("trace-search").value.trim().toLowerCase();
  const status = document.getElementById("status-filter").value;

  return state.items.filter((item) => {
    const matchesStatus = status === "all" || item.status === status;
    if (!matchesStatus) {
      return false;
    }

    if (!search) {
      return true;
    }

    const haystack = [
      item.traceId,
      item.status,
      item.pipelineRoute,
      item.selectedRoute,
      item.usedModel,
      item.subject,
      item.gradeBand,
      item.lastStepName,
      item.ocrQuality
    ]
      .filter(Boolean)
      .join(" ")
      .toLowerCase();

    return haystack.includes(search);
  });
}

function renderTraceList() {
  const items = getFilteredItems();
  const container = document.getElementById("trace-list");
  document.getElementById("trace-count").textContent = `${items.length} 条`;

  if (items.length === 0) {
    container.innerHTML = `<p class="placeholder">没有匹配到 trace。</p>`;
    return;
  }

  container.innerHTML = items
    .map((item) => {
      const route = item.pipelineRoute || item.selectedRoute || "pending";
      const active = item.traceId === state.selectedTraceId ? "active" : "";
      return `
        <button class="trace-item ${active}" data-trace-id="${escapeHtml(item.traceId)}" type="button">
          <div class="trace-item-top">
            <strong>${escapeHtml(item.traceId)}</strong>
            ${badge(item.status || "unknown", statusTone(item.status))}
          </div>
          <div class="trace-item-row">
            ${badge(route, routeTone(route))}
            ${badge(item.usedModel || "pending")}
          </div>
          <div class="trace-item-row muted">
            <span>${escapeHtml(item.subject || "unknown")} / ${escapeHtml(item.gradeBand || "unknown")}</span>
            <span>${escapeHtml(item.clientSource || "unknown")}</span>
          </div>
          <div class="trace-item-row muted">
            <span>OCR: ${escapeHtml(item.ocrQuality || "unknown")}</span>
            <span>${item.autoCropApplied ? "已裁题" : "未裁题"}</span>
          </div>
          <div class="trace-item-row muted">
            <span>${escapeHtml(item.lastStepName || "pending")}</span>
            <span>${item.processingMs ? `${item.processingMs} ms` : "--"}</span>
          </div>
        </button>
      `;
    })
    .join("");

  container.querySelectorAll("[data-trace-id]").forEach((button) => {
    button.addEventListener("click", () => {
      state.selectedTraceId = button.getAttribute("data-trace-id");
      renderTraceList();
      loadTrace(state.selectedTraceId);
    });
  });
}

function renderKeyValueGrid(title, entries) {
  return `
    <section class="info-block">
      <h3>${escapeHtml(title)}</h3>
      <div class="kv-grid">
        ${entries
          .map(
            ([label, value]) => `
              <div class="kv-row">
                <span>${escapeHtml(label)}</span>
                <strong>${escapeHtml(value)}</strong>
              </div>
            `
          )
          .join("")}
      </div>
    </section>
  `;
}

function renderTraceDetail(trace) {
  const request = trace.request || {};
  const clientTrace = request.clientTrace || {};
  const routing = trace.routing || {};
  const prompt = trace.prompt || {};
  const result = trace.result || {};

  const route = result.pipelineRoute || routing.selectedRoute || "pending";
  const subject = request.subject || "unknown";
  const gradeBand = request.gradeBand || "unknown";
  const processingMs = result.processingMs || "--";
  const recognizedText = request.recognizedText || request.recognizedTextPreview || "";

  const container = document.getElementById("trace-detail");
  container.innerHTML = `
    <article class="result-card">
      <div class="detail-head">
        <div>
          <h2>Trace ${escapeHtml(trace.traceId)}</h2>
          <p class="muted">按阶段查看客户端、OCR、本地求解和模型调用全过程。</p>
        </div>
        <div class="trace-item-row">
          ${badge(trace.status || "unknown", statusTone(trace.status))}
          ${badge(route, routeTone(route))}
        </div>
      </div>

      <div class="meta-strip">
        <span>开始：<strong>${escapeHtml(trace.startedAt)}</strong></span>
        <span>结束：<strong>${escapeHtml(trace.finishedAt || "running")}</strong></span>
        <span>耗时：<strong>${escapeHtml(processingMs)} ms</strong></span>
      </div>

      <div class="detail-grid">
        ${renderKeyValueGrid("请求概览", [
          ["学科", subject],
          ["年级", gradeBand],
          ["答题风格", request.answerStyle || "unknown"],
          ["客户端来源", clientTrace.source || "unknown"],
          ["识别行数", clientTrace.recognizedLineCount ?? request.recognizedLineCount ?? "--"],
          ["识别长度", clientTrace.recognizedTextLength ?? request.recognizedTextLength ?? "--"]
        ])}

        ${renderKeyValueGrid("OCR 与裁题", [
          ["OCR 质量", clientTrace.ocrQuality || "unknown"],
          ["OCR 策略", clientTrace.ocrPass || "unknown"],
          ["平均置信度", clientTrace.ocrAverageConfidence != null ? `${Math.round(clientTrace.ocrAverageConfidence * 100)}%` : "--"],
          ["自动裁题", clientTrace.autoCropApplied ? "是" : "否"],
          ["裁题覆盖率", clientTrace.autoCropCoverage != null ? `${Math.round(clientTrace.autoCropCoverage * 100)}%` : "--"],
          ["OCR 耗时", clientTrace.ocrDurationMs != null ? `${clientTrace.ocrDurationMs} ms` : "--"]
        ])}

        ${renderKeyValueGrid("路由与模型", [
          ["最终路由", route],
          ["选路原因", routing.reason || "unknown"],
          ["最终模型", result.usedModel || "pending"],
          ["最后阶段", (trace.steps || []).at(-1)?.name || "pending"],
          ["shouldRetakePhoto", result.shouldRetakePhoto ? "true" : "false"],
          ["retakeReason", result.retakeReason || "--"]
        ])}
      </div>

      <section class="info-block">
        <h3>客户端上传与 OCR 识别</h3>
        <pre class="code-block">${prettyJson({
          request: {
            sessionId: request.sessionId,
            subject: request.subject,
            gradeBand: request.gradeBand,
            answerStyle: request.answerStyle,
            clientTrace
          },
          recognizedText
        })}</pre>
      </section>

      <section class="info-block">
        <h3>提交给大模型的系统提示词</h3>
        <pre class="code-block">${escapeHtml(prompt.systemPrompt || "")}</pre>
      </section>

      <section class="info-block">
        <h3>提交给大模型的完整上下文</h3>
        <pre class="code-block">${escapeHtml(prompt.userPrompt || "")}</pre>
      </section>

      <section class="info-block">
        <h3>模型尝试记录</h3>
        <pre class="code-block">${prettyJson(trace.modelAttempts || [])}</pre>
      </section>

      <section class="info-block">
        <h3>处理时间线</h3>
        <pre class="code-block">${prettyJson(trace.steps || [])}</pre>
      </section>

      <section class="info-block">
        <h3>最终结果</h3>
        <pre class="code-block">${prettyJson(result)}</pre>
      </section>

      ${
        trace.error
          ? `
            <section class="info-block">
              <h3>错误信息</h3>
              <pre class="code-block">${prettyJson(trace.error)}</pre>
            </section>
          `
          : ""
      }
    </article>
  `;
}

async function fetchJson(url) {
  const response = await fetch(url);
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.error || "request failed");
  }
  return data;
}

async function loadSummary() {
  state.summary = await fetchJson("/api/debug/overview?limit=200");
  renderSummary(state.summary);
}

async function loadTraceList() {
  const data = await fetchJson("/api/debug/traces?limit=60");
  state.items = data.items || [];

  if (!state.selectedTraceId && state.items.length > 0) {
    state.selectedTraceId = state.items[0].traceId;
  }

  if (state.selectedTraceId && !state.items.some((item) => item.traceId === state.selectedTraceId)) {
    state.selectedTraceId = state.items[0]?.traceId || null;
  }

  renderTraceList();
}

async function loadTrace(traceId) {
  if (!traceId) {
    document.getElementById("trace-detail").innerHTML = `<p class="placeholder">请选择一条 trace 查看完整过程。</p>`;
    return;
  }

  try {
    const trace = await fetchJson(`/api/debug/traces/${traceId}`);
    renderTraceDetail(trace);
  } catch (error) {
    document.getElementById("trace-detail").innerHTML = `<p class="error">${escapeHtml(error.message || "加载 trace 失败。")}</p>`;
  }
}

async function refreshDashboard() {
  try {
    await Promise.all([loadSummary(), loadTraceList()]);
    await loadTrace(state.selectedTraceId);
  } catch (error) {
    document.getElementById("trace-detail").innerHTML = `<p class="error">${escapeHtml(error.message || "加载监控台失败。")}</p>`;
  }
}

function updateStreamStatus(status, label) {
  state.streamStatus = status;
  const root = document.getElementById("stream-status");
  root.innerHTML = `
    <span class="status-dot ${escapeHtml(status)}"></span>
    <strong>${escapeHtml(label)}</strong>
  `;
}

function scheduleRefresh(delay = 300) {
  if (state.refreshTimer) {
    clearTimeout(state.refreshTimer);
  }

  state.refreshTimer = setTimeout(() => {
    state.refreshTimer = null;
    refreshDashboard();
  }, delay);
}

function startEventStream() {
  const stream = new EventSource("/api/debug/events");
  updateStreamStatus("pending", "实时连接中");

  stream.addEventListener("connected", () => {
    updateStreamStatus("live", "实时监控已连接");
  });

  stream.addEventListener("trace_updated", () => {
    updateStreamStatus("live", "实时监控已连接");
    scheduleRefresh(200);
  });

  stream.addEventListener("heartbeat", () => {
    updateStreamStatus("live", "实时监控已连接");
  });

  stream.onerror = () => {
    updateStreamStatus("down", "实时连接断开，正在回退轮询");
    stream.close();
    setTimeout(startEventStream, 3000);
  };
}

document.getElementById("manual-refresh").addEventListener("click", () => {
  refreshDashboard();
});

document.getElementById("status-filter").addEventListener("change", () => {
  renderTraceList();
});

document.getElementById("trace-search").addEventListener("input", () => {
  renderTraceList();
});

refreshDashboard();
startEventStream();
setInterval(() => {
  if (state.streamStatus !== "live") {
    refreshDashboard();
  }
}, 10000);
