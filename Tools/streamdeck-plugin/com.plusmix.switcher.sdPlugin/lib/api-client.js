// PlusMix 本地 API 的客户端（docs/api.md）：WS /api/v1/events 收整快照 + tally，连接上直接发命令拿回执。
// 断线每 2 s 重连；快照缓存在 .snapshot，时钟在 .clock（hello 里带）。
// WebSocket 构造函数与计时器由调用方给（bin/plugin.js 给 ws 包的 WebSocket）：这个文件不 import ws，test/cases.js 在 node 与 JXA 里
// 都能拿假 socket / 假计时器排事件顺序（W2-C4 / D17）。JXA 没有 node:events，scripts/run-jxa.sh 垫一个只有 on / emit 的。
// Codex 10-24 审计（W2-C5）：NS10——快照里 state.inputs / outputs 不是对象数组的丢掉（tally.js 对它们 find / filter，畸形的抛 TypeError、
// 带走整个插件进程），监听回调抛的异常也接住只记一行；NS11——日志里不出现 token（连接地址带 ?token=，记日志用 endpoint / redactToken）。
import { EventEmitter } from "node:events";
import { classifyMessage } from "./tally.js";

/** 文字里的 token= 查询项整项去掉（日志用，NS11）："…/events?token=abc&x=1" → "…/events?x=1"，"…/events?token=abc" → "…/events"。 */
export function redactToken(text) {
  return String(text).replace(/(^|[?&\s])token=[^&#\s]*(&?)/gi, (match, sep, amp) => (sep === "?" || sep === "&" ? (amp ? sep : "") : sep));
}

/** 按钮会遍历的两张表（state.inputs / outputs）：有就得是对象数组；没有这两个键的照收（tally.js 按空表算）。 */
function snapshotTablesOK(message) {
  const state = message && message.state;
  if (state === null || typeof state !== "object") return true;
  const ok = (table) => table == null || (Array.isArray(table) && table.every((e) => e !== null && typeof e === "object"));
  return ok(state.inputs) && ok(state.outputs);
}

export class SwitcherClient extends EventEmitter {
  constructor({ host = "127.0.0.1", port = 8765, token = "", WebSocket = null,
                setTimer = (f, ms) => setTimeout(f, ms), clearTimer = (t) => clearTimeout(t) } = {}) {
    super();
    this.host = host;
    this.port = port;
    this.token = token;
    this.WebSocket = WebSocket;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.snapshot = null;
    this.clock = null;
    this.connected = false;
    this.ws = null;
    this.nextID = 1;
    this.pending = new Map();
    this.timer = null;
    this.closed = false;
  }

  get url() {
    const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
    return `ws://${this.host}:${this.port}/api/v1/events${q}`;
  }

  /** 日志里写的连接目标：只有 host:port（url 带 ?token=，NS11）。 */
  get endpoint() {
    return `${this.host}:${this.port}`;
  }

  /** 监听回调抛的异常不往外冒（NS10）：原来重画一抛就顺着 ws 的事件处理冒上去、带走插件进程（断开时还会漏掉重连）。记一行 log，事件照常往下走。 */
  emit(event, ...args) {
    try {
      return super.emit(event, ...args);
    } catch (e) {
      if (event !== "log") {
        try { super.emit("log", `${event} 的回调出错：${redactToken(e && e.message)}`); } catch (e2) { /* 记日志的回调也出错：不管 */ }
      }
      return true;
    }
  }

  connect() {
    this.closed = false;
    this.open();
  }

  /** 改连接设置（全局设置面板）：变了就关掉当前连接、清掉旧那台的快照与时钟（别拿它算开关），按新设置重连。 */
  reconfigure({ host, port, token }) {
    const changed = host !== this.host || port !== this.port || token !== this.token;
    this.host = host; this.port = port; this.token = token;
    if (changed) {
      this.close();
      this.snapshot = null;
      this.clock = null;
      this.connect();
    }
  }

  open() {
    if (this.closed || this.ws) return;
    let ws;
    try {
      ws = new this.WebSocket(this.url);
    } catch (e) {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    // 每个回调先认连接（W2-C4 / D17）：不是当前这条就什么都不做。改过设置、close() 掉的旧 socket，它的 close / message / error 是异步后到的——
    // 原来旧 close 无条件清空 this.ws，新连接明明开着却被当成断开（Cut 报"没连上"）、再起第三条、第二条没人关。
    const current = () => this.ws === ws;
    ws.on("open", () => { if (!current()) return; this.connected = true; this.emit("connected"); });
    ws.on("message", (data) => { if (current()) this.handle(String(data)); });
    ws.on("error", (err) => { if (current()) this.emit("log", `连接出错：${redactToken(err && err.message)}`); });
    ws.on("close", () => {
      if (!current()) return;
      this.ws = null;
      const was = this.connected;
      this.connected = false;
      this.rejectPending();
      if (was) this.emit("disconnected");
      this.scheduleReconnect();
    });
  }

  /** 发在当前连接上、还没回执的命令一并作废（连接断了 / 主动关了）。 */
  rejectPending() {
    for (const [, p] of this.pending) p.reject(new Error("连接断了"));
    this.pending.clear();
  }

  scheduleReconnect() {
    if (this.closed || this.timer) return;
    this.timer = this.setTimer(() => { this.timer = null; this.open(); }, 2000);
  }

  close() {
    this.closed = true;
    if (this.timer) { this.clearTimer(this.timer); this.timer = null; }
    if (this.ws) { try { this.ws.close(); } catch (e) { /* 已经关了 */ } this.ws = null; }
    this.connected = false;
    this.rejectPending();   // 它后到的 close 已经不是当前连接、不会再管这些命令：在这里作废，不留给下一条连接
  }

  handle(text) {
    const { type, message } = classifyMessage(text);
    switch (type) {
      case "hello":
        this.clock = message.clock || null;
        break;
      case "snapshot":
        if (!snapshotTablesOK(message)) {
          this.emit("log", "快照格式不对（state.inputs / state.outputs 不是对象数组），丢掉这条");
          break;
        }
        this.snapshot = message;
        this.emit("snapshot", message);
        break;
      case "receipt":
      case "receipts":
      case "error": {
        const p = message.id != null ? this.pending.get(message.id) : null;
        if (!p) break;
        this.pending.delete(message.id);
        if (type === "error") p.reject(new Error(message.error)); else p.resolve(message);
        break;
      }
      default:
        break;
    }
  }

  /** 发一条命令，等回执（5 s 超时）。 */
  send(command) {
    return new Promise((resolve, reject) => {
      if (!this.ws || !this.connected) return reject(new Error("没连上 PlusMix"));
      const id = this.nextID++;
      const timeout = this.setTimer(() => { this.pending.delete(id); reject(new Error("回执超时")); }, 5000);
      this.pending.set(id, {
        resolve: (m) => { this.clearTimer(timeout); resolve(m); },
        reject: (e) => { this.clearTimer(timeout); reject(e); },
      });
      this.ws.send(JSON.stringify({ id, command }));
    });
  }
}
