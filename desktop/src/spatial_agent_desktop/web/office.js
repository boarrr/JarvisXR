// Spatial Agent office: a live, clickable view of the daemon's agents.
const STATE = { threads: [], selected: "", status: {}, link: {}, workspace: {} };

const STATUS_COLOR = {
  working: "#38d39f",
  listening: "#7bf5ff",
  waiting_user: "#ffd166",
  error: "#f97a6d",
  complete: "#8ab4ff",
  idle: "#6b9aa5",
};

function api() {
  return window.pywebview && window.pywebview.api ? window.pywebview.api : null;
}

function $(id) {
  return document.getElementById(id);
}

async function refresh() {
  const a = api();
  if (!a) return;
  const [status, link, threads, workspace] = await Promise.all([
    a.get_status(),
    a.get_link_info(),
    a.list_threads(),
    a.selected_workspace(),
  ]);
  STATE.status = status || {};
  STATE.link = link || {};
  STATE.threads = threads || [];
  STATE.workspace = workspace || {};
  if (STATE.selected && !STATE.threads.some((t) => t.id === STATE.selected)) {
    STATE.selected = "";
  }
  renderChips();
  renderLinkBar();
  renderOffice();
  renderChat();
}

function renderChips() {
  const s = STATE.status || {};
  const chips = [
    `repo: ${(STATE.workspace && STATE.workspace.name) || "none"}`,
    `provider: ${s.provider || "?"}`,
    `harness: ${s.harness || "?"}`,
    `port: ${s.port ?? "?"}`,
    s.paused ? "PAUSED" : "running",
    s.auth_required ? "auth" : "no-auth",
  ];
  $("chips").innerHTML = chips
    .map((c) => `<span class="chip${c === "PAUSED" ? " warn" : ""}">${c}</span>`)
    .join("");
  $("btn-pause").textContent = s.paused ? "Resume" : "Pause";
  $("office-empty").style.display = STATE.threads.length ? "none" : "flex";
}

function renderLinkBar() {
  const l = STATE.link || {};
  const urls = (l.ws_urls || []).map((u) => `<code>${u}</code>`).join(" ");
  $("linkbar").innerHTML =
    `<span>headset URL: ${urls || "—"}</span>` +
    `<span>CA: <code>${(l.ca_fingerprint || "").slice(0, 16) || "—"}</code></span>` +
    `<span>version: ${l.version || "?"}</span>` +
    `<span>discovery: ${l.discovery_enabled ? "on :" + l.discovery_port : "off"}</span>`;
}

function drawAvatar(ctx, x, y, r, thread, selected) {
  const color = STATUS_COLOR[thread.status] || STATUS_COLOR.idle;
  ctx.save();
  if (thread.status === "working") {
    const glow = 0.5 + 0.5 * Math.sin(Date.now() / 220);
    ctx.shadowColor = color;
    ctx.shadowBlur = 12 + 14 * glow;
  }
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();
  ctx.restore();
  ctx.lineWidth = selected ? 3 : 1;
  ctx.strokeStyle = selected ? "#ffffff" : "rgba(255,255,255,0.25)";
  ctx.beginPath();
  ctx.arc(x, y, r, 0, Math.PI * 2);
  ctx.stroke();
  ctx.fillStyle = "#eaf6f8";
  ctx.font = "12px -apple-system, system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.fillText(thread.title || thread.id.slice(0, 8), x, y + r + 16);
  ctx.fillStyle = "rgba(234,246,248,0.55)";
  ctx.font = "10px -apple-system, system-ui, sans-serif";
  ctx.fillText(thread.status, x, y + r + 30);
}

function renderOffice() {
  const canvas = $("office");
  const wrap = canvas.parentElement;
  const dpr = window.devicePixelRatio || 1;
  const w = wrap.clientWidth;
  const h = wrap.clientHeight;
  if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
    canvas.width = w * dpr;
    canvas.height = h * dpr;
  }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);

  // Office floor grid.
  ctx.strokeStyle = "rgba(20,80,95,0.35)";
  ctx.lineWidth = 1;
  for (let gx = 0; gx < w; gx += 40) {
    ctx.beginPath();
    ctx.moveTo(gx, 0);
    ctx.lineTo(gx, h);
    ctx.stroke();
  }
  for (let gy = 0; gy < h; gy += 40) {
    ctx.beginPath();
    ctx.moveTo(0, gy);
    ctx.lineTo(w, gy);
    ctx.stroke();
  }

  const cols = Math.max(1, Math.floor(w / 140));
  const r = 26;
  const padX = 70;
  const padY = 70;
  STATE.threads.forEach((thread, i) => {
    const cx = padX + (i % cols) * 140;
    const cy = padY + Math.floor(i / cols) * 110;
    thread._x = cx;
    thread._y = cy;
    thread._r = r;
    drawAvatar(ctx, cx, cy, r, thread, thread.id === STATE.selected);
  });
}

function renderChat() {
  const thread = STATE.threads.find((t) => t.id === STATE.selected);
  $("chat-title").textContent = thread ? `${thread.title}  ·  ${thread.status}` : "Select an agent";
  const log = $("chat-log");
  if (!thread) {
    log.innerHTML = "";
    return;
  }
  log.innerHTML = (thread.messages || [])
    .map((m) => {
      const role = (m.role || "assistant").toLowerCase();
      const text = (m.content || "").replace(/</g, "&lt;");
      return `<div class="msg ${role}"><div class="who">${role}</div><div class="body">${text}</div></div>`;
    })
    .join("");
  log.scrollTop = log.scrollHeight;
}

function initEvents() {
  const canvas = $("office");
  canvas.addEventListener("click", (event) => {
    const rect = canvas.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    for (const t of STATE.threads) {
      const dx = x - (t._x || 0);
      const dy = y - (t._y || 0);
      if (dx * dx + dy * dy <= (t._r || 0) ** 2) {
        STATE.selected = t.id;
        renderOffice();
        renderChat();
        return;
      }
    }
  });

  $("btn-new").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    await a.create_thread("New agent");
    refresh();
  });

  $("btn-workspace").addEventListener("click", showWorkspace);

  $("dialog-close").addEventListener("click", () => $("dialog").close());

  $("btn-mission").addEventListener("click", () => {
    openDialog(
      `<p>New mission (fans out to N agents, each its own worktree)</p>` +
        `<input id="m-goal" placeholder="Goal" style="width:100%;padding:8px;margin-bottom:8px" />` +
        `<p>Workers: <input id="m-count" type="number" min="1" max="8" value="3" style="width:60px" />` +
        `  Budget min: <input id="m-mins" type="number" min="0" value="0" style="width:60px" />` +
        `  Budget $: <input id="m-cost" type="number" min="0" step="0.5" value="0" style="width:70px" />` +
        `  <label><input id="m-directed" type="checkbox" /> Director (auto-decompose)</label></p>` +
        `<menu><button id="m-create">Create mission</button></menu>`
    );
    $("m-create").addEventListener("click", async () => {
      const a = api();
      const goal = $("m-goal").value.trim();
      const count = parseInt($("m-count").value, 10) || 3;
      const seconds = (parseFloat($("m-mins").value) || 0) * 60;
      const cost = parseFloat($("m-cost").value) || 0;
      const directed = $("m-directed").checked;
      if (!a || !goal) return;
      $("dialog").close();
      await a.create_mission(goal, count, "", "", Math.round(seconds), cost, directed);
      refresh();
    });
  });

  $("btn-missions").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    const missions = await a.list_missions();
    if (!missions.length) {
      openDialog("<p>No missions yet.</p>");
      return;
    }
    const rows = missions
      .map(
        (m) =>
          `<div class="devrow"><span>${escapeHtml(m.goal)} · ${m.status} · ${m.agents.length} agents</span>` +
          `<button data-compare="${m.id}">compare</button></div>`
      )
      .join("");
    openDialog(`<p>Missions</p>${rows}`);
    $("dialog-body").querySelectorAll("[data-compare]").forEach((btn) =>
      btn.addEventListener("click", () => showCompare(btn.getAttribute("data-compare")))
    );
  });

  $("btn-pause").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    await a.set_paused(!STATE.status.paused);
    refresh();
  });

  $("btn-pair").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    const info = await a.pairing_payload();
    openDialog(
      `<p>Pair a headset — point it at this and scan with the passthrough camera:</p>` +
        (info.qr ? `<img src="${info.qr}" width="520" height="520" alt="pairing QR" />` : "") +
        `<p>or enter the code: <code>${escapeHtml(info.code || "")}</code></p>` +
        `<p style="color:#7fa6bd;font-size:12px">${escapeHtml(info.url || "")}</p>`
    );
  });

  $("btn-devices").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    const devices = await a.list_devices();
    const rows = devices.length
      ? devices
          .map(
            (d) =>
              `<div class="devrow"><span>${d.name || d.id.slice(0, 8)}</span>` +
              `<button data-revoke="${d.id}">revoke</button></div>`
          )
          .join("")
      : "<p>No paired devices.</p>";
    openDialog(`<p>Paired devices</p>${rows}`);
    $("dialog-body").querySelectorAll("[data-revoke]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        await a.revoke_device(btn.getAttribute("data-revoke"));
        $("btn-devices").click();
      });
    });
  });

  $("chat-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const a = api();
    const input = $("chat-input");
    const text = input.value.trim();
    if (!a || !STATE.selected || !text) return;
    input.value = "";
    await a.send_message(STATE.selected, text);
    refresh();
  });
}

function openDialog(html) {
  $("dialog-body").innerHTML = html;
  $("dialog").showModal();
}

function escapeHtml(value) {
  return String(value == null ? "" : value).replace(/[&<>"]/g, (c) => {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
  });
}

async function showWorkspace() {
  const a = api();
  if (!a) return;
  const workspaces = await a.list_workspaces();
  const selected = STATE.workspace && STATE.workspace.id;
  const rows = workspaces.length
    ? workspaces
        .map(
          (w) =>
            `<div class="devrow"><span>${w.id === selected ? "● " : ""}${escapeHtml(
              w.name
            )} <span style="color:#7fa6bd">${escapeHtml(w.path)}</span></span>` +
            `<span><button data-select="${w.id}">use</button> <button data-remove="${w.id}">remove</button></span></div>`
        )
        .join("")
    : "<p>No repositories yet. Choose a folder.</p>";
  openDialog(
    `<p>Repository (agents edit code here)</p>${rows}` +
      `<menu><button id="ws-choose">Choose folder…</button></menu>`
  );
  const body = $("dialog-body");
  body.querySelectorAll("[data-select]").forEach((b) =>
    b.addEventListener("click", async () => {
      await a.select_workspace(b.getAttribute("data-select"));
      $("dialog").close();
      refresh();
    })
  );
  body.querySelectorAll("[data-remove]").forEach((b) =>
    b.addEventListener("click", async () => {
      await a.remove_workspace(b.getAttribute("data-remove"));
      showWorkspace();
      refresh();
    })
  );
  $("ws-choose").addEventListener("click", async () => {
    const path = await a.choose_folder();
    if (path) {
      await a.add_workspace(path, "");
      $("dialog").close();
      refresh();
    }
  });
}

async function showCompare(missionId) {
  const a = api();
  if (!a) return;
  const agents = await a.mission_compare(missionId);
  const blocks = agents
    .map((agent) => {
      const files = (agent.files || [])
        .map(
          (f) =>
            `<li>${escapeHtml(f.path)} <span style="color:#7fa6bd">+${f.additions || 0}/-${
              f.deletions || 0
            }</span></li>`
        )
        .join("");
      const runId = agent.run_id || "";
      return (
        `<div class="devrow"><div><b>${escapeHtml((agent.thread_id || "").slice(0, 14))}</b>` +
        `<ul style="margin:6px 0 0;padding-left:18px">${files || "<li>no changes</li>"}</ul></div>` +
        (runId ? `<button data-merge="${missionId}|${runId}">merge</button>` : "") +
        `</div>`
      );
    })
    .join("");
  openDialog(`<p>Compare agents (pick-one merge)</p>${blocks || "<p>No agents.</p>"}`);
  $("dialog-body").querySelectorAll("[data-merge]").forEach((btn) =>
    btn.addEventListener("click", async () => {
      const [mid, rid] = btn.getAttribute("data-merge").split("|");
      const result = await a.mission_merge(mid, rid);
      $("dialog").close();
      refresh();
      if (!result || !result.merged) {
        openDialog(`<p>Merge failed: ${escapeHtml((result && result.error) || "unknown")}</p>`);
      }
    })
  );
}

window.addEventListener("pywebviewready", () => {
  initEvents();
  refresh();
  setInterval(refresh, 1500);
});
