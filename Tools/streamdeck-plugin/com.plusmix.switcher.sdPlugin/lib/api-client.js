// PlusMix 本地 API 的客户端（docs/api.md）：WS /api/v1/events 收整快照 + tally，连接上直接发命令拿回执。
// 断线每 2 s 重连；快照缓存在 .snapshot，时钟在 .clock（hello 里带）。
// WebSocket 构造函数与计时器由调用方给（bin/plugin.js 给 ws 包的 WebSocket）：这个文件不 import ws，test/cases.js 在 node 与 JXA 里
// 都能拿假 socket / 假计时器排事件顺序（W2-C4 / D17）。JXA 没有 node:events，scripts/run-jxa.sh 垫一个只有 on / emit 的。
import { EventEmitter } from "node:events";
import { classifyMessage } from "./tally.js";

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
    ws.on("error", (err) => { if (current()) this.emit("log", `连接出错：${err.message}`); });
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
