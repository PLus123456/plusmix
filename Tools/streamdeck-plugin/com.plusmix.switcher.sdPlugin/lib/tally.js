// 纯函数：快照 → 按钮样式 / 按下 → 命令。不碰 Stream Deck SDK 也不碰网络，node --test 和 JXA（scripts/run-jxa.sh）都能跑。
// 颜色按设计方案 §1.1 / 落地方案决策 3：PGM 红、PVW 绿（广播惯例）。
// 转场 1–4（W5-M，提案 020 的槽）：按下 = useTransitionSlot(n, start: true)（设置成"选中"时 start: false）；颜色跟当前槽——
// 当前槽（T-bar / 回车用的）蓝、它正在执行红、别的灰；字 = "转场 n" + 槽的效果与时长。
// W5-O：按下之后怎么回应（pressFeedback）也在这里——命令被拒（例如提案 029 没选输入的 Stinger 槽）闪一下警告。

export const COLORS = {
  off: "#2b2b2b",
  program: "#d62828",
  preview: "#2a9d3b",
  overlay: "#e09f1f",
  record: "#d62828",
  stream: "#1f6fe0",
  ftb: "#111111",
  action: "#3a3a3a",
  slotCurrent: "#3d85f2",
  disconnected: "#555555",
  text: "#ffffff",
};

/** 快照里一路输入的 tally；没有快照或没有这路 → 都 false。 */
export function tallyFor(snapshot, input) {
  if (!snapshot || !input) return { program: false, preview: false };
  const t = snapshot.tally && snapshot.tally[String(input)];
  if (t) return { program: !!t.program, preview: !!t.preview };
  const s = snapshot.state || {};
  return { program: s.program === input, preview: s.preview === input };
}

/** 输入名（没有就用编号）。 */
export function inputName(snapshot, input) {
  const inputs = (snapshot && snapshot.state && snapshot.state.inputs) || [];
  const found = inputs.find((i) => i.number === input);
  return found ? found.name : input ? String(input) : "";
}

/** 按种类和编号找输出：number 给了就按编号，否则该种类里编号最小的。 */
export function outputOf(snapshot, kind, number) {
  const outputs = (snapshot && snapshot.state && snapshot.state.outputs) || [];
  if (number) return outputs.find((o) => o.number === number && o.kind === kind) || null;
  const same = outputs.filter((o) => o.kind === kind).sort((a, b) => a.number - b.number);
  return same[0] || null;
}

/** hello 里的时钟 → 每秒拍数；没有时钟按 60。frameDuration 是"一拍的时长（秒）"的分数。 */
export function fpsFrom(clock) {
  const d = clock && clock.frameDuration;
  if (!d || !d.numerator || !d.denominator) return 60;
  return d.denominator / d.numerator;
}

function num(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? Math.round(n) : fallback;
}

/** 秒数写法：最多两位小数、去掉末尾的 0（0.5 / 1 / 0.75），与 App 的时长分段同一口径。 */
function secondsText(seconds) {
  return (Math.round(seconds * 100) / 100).toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

const SLOT_EFFECTS = { fade: "Fade", wipe: "Wipe", zoom: "Zoom", stinger: "Stinger", cut: "Cut" };
const WIPE_ARROWS = { leftToRight: "→", rightToLeft: "←", topToBottom: "↓", bottomToTop: "↑", diagonal: "↘" };

/** 转场槽按钮的小字："Fade 0.5s" / "Wipe → 1s" / "Cut" / "未选输入"（Stinger 没选输入）；9 个字放不下就只写效果。秒按帧率换。 */
export function slotSublabel(slot, fps) {
  if (!slot) return "";
  if (slot.type === "cut") return "Cut";
  if (slot.type === "stinger" && (!slot.stinger || slot.stinger.input == null)) return "未选输入";
  let effect = SLOT_EFFECTS[slot.type] || String(slot.type);
  if (slot.type === "wipe" && slot.wipe && WIPE_ARROWS[slot.wipe.direction]) effect += " " + WIPE_ARROWS[slot.wipe.direction];
  const text = `${effect} ${secondsText((slot.durationTicks || 0) / (fps || 60))}s`;
  return Array.from(text).length <= 9 ? text : effect;
}

/**
 * 一个按钮此刻该长什么样。kind：cut / auto / slot / preview / program / tally / overlay / record / stream / ftb。
 * 返回 { background, label, sublabel, border }。fps 只有转场槽的小字要用（毫秒 → 秒），不给按 60。
 */
export function keyStyle(kind, snapshot, settings, connected, fps) {
  const s = settings || {};
  if (!connected) return { background: COLORS.disconnected, label: labelFor(kind, s), sublabel: "未连接", border: null };
  const state = (snapshot && snapshot.state) || {};
  switch (kind) {
    case "cut":
      return { background: COLORS.action, label: "CUT", sublabel: "", border: null };
    case "auto": {
      const t = state.transition || {};
      const active = t.startTick != null || (t.progress || 0) > 0;
      return { background: active ? COLORS.program : COLORS.action, label: "AUTO", sublabel: s.mode === "fade" ? `${num(s.durationMs, 500)} ms` : t.type || "", border: null };
    }
    case "slot": {
      const n = num(s.slot, 1);
      const t = state.transition || {};
      const active = t.startTick != null || (t.progress || 0) > 0;
      const current = t.currentSlot === n;
      const background = current ? (active ? COLORS.program : COLORS.slotCurrent) : COLORS.action;
      return { background, label: `转场 ${n}`, sublabel: slotSublabel((t.slots || [])[n - 1], fps), border: null };
    }
    case "preview":
    case "program":
    case "tally": {
      const input = num(s.input, 0);
      const t = tallyFor(snapshot, input);
      const background = t.program ? COLORS.program : t.preview ? COLORS.preview : COLORS.off;
      // 同时在 PGM 和 PVW（转场中）：红底绿边
      const border = t.program && t.preview ? COLORS.preview : null;
      const prefix = kind === "preview" ? "PVW" : kind === "program" ? "PGM" : "";
      return { background, label: `${prefix} ${input || "?"}`.trim(), sublabel: inputName(snapshot, input), border };
    }
    case "overlay": {
      const channel = num(s.channel, 1);
      const o = (state.overlays || [])[channel - 1] || {};
      const visible = o.input != null && (o.on || (o.animProgress || 0) > 0);
      return { background: visible ? COLORS.overlay : COLORS.off, label: `OVL ${channel}`, sublabel: o.input ? inputName(snapshot, o.input) : "", border: null };
    }
    case "record": {
      const o = outputOf(snapshot, "record", num(s.output, 0));
      return { background: o && o.enabled ? COLORS.record : COLORS.off, label: "REC", sublabel: o ? o.name : "无录制输出", border: null };
    }
    case "stream": {
      const o = outputOf(snapshot, "stream", num(s.output, 0));
      return { background: o && o.enabled ? COLORS.stream : COLORS.off, label: "LIVE", sublabel: o ? o.name : "无推流输出", border: null };
    }
    case "ftb": {
      const on = !!(state.ftb && state.ftb.on);
      return { background: on ? COLORS.ftb : COLORS.off, label: "FTB", sublabel: on ? "黑场" : "", border: on ? COLORS.text : null };
    }
    default:
      return { background: COLORS.off, label: kind, sublabel: "", border: null };
  }
}

function labelFor(kind, s) {
  switch (kind) {
    case "preview": return `PVW ${num(s.input, 0) || "?"}`;
    case "program": return `PGM ${num(s.input, 0) || "?"}`;
    case "tally": return `${num(s.input, 0) || "?"}`;
    case "overlay": return `OVL ${num(s.channel, 1)}`;
    case "record": return "REC";
    case "stream": return "LIVE";
    case "ftb": return "FTB";
    case "auto": return "AUTO";
    case "slot": return `转场 ${num(s.slot, 1)}`;
    default: return "CUT";
  }
}

/**
 * 按下去发什么命令（本地 API 的 Command JSON）。返回 { command } 或 { error }。开关型按当前快照决定 on / off。
 */
export function commandFor(kind, snapshot, settings, fps) {
  const s = settings || {};
  const state = (snapshot && snapshot.state) || null;
  switch (kind) {
    case "cut":
      return { command: { cut: {} } };
    case "auto":
      if (s.mode === "fade") {
        const ticks = Math.max(0, Math.round((num(s.durationMs, 500) / 1000) * (fps || 60)));
        return { command: { fade: { durationTicks: ticks } } };
      }
      return { command: { autoTransition: {} } };
    case "slot": {
      const n = num(s.slot, 1);
      if (n < 1 || n > 4) return { error: "转场槽要在 1–4" };
      return { command: { useTransitionSlot: { slot: n, start: s.mode !== "select" } } };
    }
    case "preview": {
      const input = num(s.input, 0);
      return input ? { command: { setPreview: { input } } } : { error: "没设输入编号" };
    }
    case "program": {
      const input = num(s.input, 0);
      return input ? { command: { setProgram: { input } } } : { error: "没设输入编号" };
    }
    case "tally": {
      const input = num(s.input, 0);
      return input ? { command: { setPreview: { input } } } : { error: "没设输入编号" };
    }
    case "overlay": {
      const channel = num(s.channel, 1);
      if (channel < 1 || channel > 4) return { error: "叠加通道要在 1–4" };
      if (!state) return { error: "还没收到状态" };
      const o = (state.overlays || [])[channel - 1] || {};
      const input = num(s.input, 0);
      const payload = { channel, on: !o.on };
      if (input && !o.on) payload.input = input;
      if (!o.on && !input && o.input == null) return { error: `叠加 ${channel} 没有输入，先在设置里填一个` };
      return { command: { overlay: payload } };
    }
    case "record": {
      const o = outputOf(snapshot, "record", num(s.output, 0));
      if (!o) return { error: "没有录制输出" };
      return { command: o.enabled ? { stopRecord: { output: o.number } } : { startRecord: { output: o.number } } };
    }
    case "stream": {
      const o = outputOf(snapshot, "stream", num(s.output, 0));
      if (!o) return { error: "没有推流输出" };
      return { command: o.enabled ? { stopStream: { output: o.number } } : { startStream: { output: o.number } } };
    }
    case "ftb":
      return { command: { ftb: { on: !(state && state.ftb && state.ftb.on) } } };
    default:
      return { error: `不认识的按钮种类 ${kind}` };
  }
}

function escapeXML(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** 144×144 的按钮图（SVG 文本）。 */
export function svgKey(style) {
  const sub = style.sublabel ? `<text x="72" y="118" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="22" fill="${COLORS.text}" text-anchor="middle" opacity="0.9">${escapeXML(clip(style.sublabel, 9))}</text>` : "";
  const border = style.border ? `<rect x="6" y="6" width="132" height="132" rx="18" fill="none" stroke="${style.border}" stroke-width="10"/>` : "";
  return `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144">` +
    `<rect width="144" height="144" rx="22" fill="${style.background}"/>${border}` +
    `<text x="72" y="${style.sublabel ? 76 : 86}" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="40" font-weight="700" fill="${COLORS.text}" text-anchor="middle">${escapeXML(style.label)}</text>${sub}</svg>`;
}

function clip(text, max) {
  const chars = Array.from(String(text));
  return chars.length > max ? chars.slice(0, max).join("") + "…" : text;
}

/** SVG → data URI（自带 base64，JXA 里没有 Buffer / btoa）。 */
export function svgDataURI(svg) {
  return "data:image/svg+xml;base64," + base64(utf8Bytes(svg));
}

function utf8Bytes(str) {
  const out = [];
  for (const ch of str) {
    let cp = ch.codePointAt(0);
    if (cp < 0x80) out.push(cp);
    else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 0x3f));
    else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
  }
  return out;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function base64(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
    const n = (a << 16) | ((b || 0) << 8) | (c || 0);
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + (b === undefined ? "=" : B64[(n >> 6) & 63]) + (c === undefined ? "=" : B64[n & 63]);
  }
  return out;
}

/** 服务端 WS 报文分类：snapshot / hello / receipt / error / stats / 其他。 */
export function classifyMessage(text) {
  try {
    const m = JSON.parse(text);
    return { type: m && m.type ? m.type : "unknown", message: m };
  } catch (e) {
    return { type: "invalid", message: null };
  }
}

/**
 * 按下之后怎么回应（W5-O）：命令被拒（WS 回 error = HTTP 400 那一类结构性非法，例如提案 029 起执行没选输入的 Stinger 槽
 * "转场 n 是 Stinger、还没选输入"；或本地就判出来的错误）→ 按钮闪一下警告（SDK 的 showAlert）+ 记 warn；
 * 状态机忽略（回执 applied: false，已是目标状态）→ 只记 info；成功 → 什么都不做。outcome = { receipt } 或 { error: "<理由>" }。
 */
export function pressFeedback(kind, outcome) {
  if (outcome && outcome.error) return { alert: true, level: "warn", log: `${kind}: ${outcome.error}` };
  if (outcome && outcome.receipt && outcome.receipt.applied === false) {
    return { alert: false, level: "info", log: `${kind}: 状态机忽略了这条命令（已是目标状态）` };
  }
  return { alert: false, level: null, log: null };
}
