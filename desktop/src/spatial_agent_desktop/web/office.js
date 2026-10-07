// Spatial Agent office: a live, clickable view of the daemon's agents.
const STATE = { threads: [], selected: "", status: {}, link: {} };

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
  const [status, link, threads] = await Promise.all([
    a.get_status(),
    a.get_link_info(),
    a.list_threads(),
  ]);
  STATE.status = status || {};
  STATE.link = link || {};
  STATE.threads = threads || [];
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

  $("btn-pause").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    await a.set_paused(!STATE.status.paused);
    refresh();
  });

  $("btn-pair").addEventListener("click", async () => {
    const a = api();
    if (!a) return;
    const code = await a.issue_pairing_code();
    openDialog(`<p>Type this on the headset (or <code>/pair</code>):</p><p><code>${code}</code></p>`);
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

window.addEventListener("pywebviewready", () => {
  initEvents();
  refresh();
  setInterval(refresh, 1500);
});
