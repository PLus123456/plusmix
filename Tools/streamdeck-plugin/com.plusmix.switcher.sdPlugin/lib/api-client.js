// Switcher 本地 API 的客户端（docs/api.md）：WS /api/v1/events 收整快照 + tally，连接上直接发命令拿回执。
// 断线每 2 s 重连；快照缓存在 .snapshot，时钟在 .clock（hello 里带）。
import { EventEmitter } from "node:events";
import WebSocket from "ws";
import { classifyMessage } from "./tally.js";

export class SwitcherClient extends EventEmitter {
  constructor({ host = "127.0.0.1", port = 8765, token = "" } = {}) {
    super();
    this.host = host;
    this.port = port;
    this.token = token;
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

  reconfigure({ host, port, token }) {
    const changed = host !== this.host || port !== this.port || token !== this.token;
    this.host = host; this.port = port; this.token = token;
    if (changed) { this.close(); this.connect(); }
  }

  open() {
    if (this.closed || this.ws) return;
    let ws;
    try {
      ws = new WebSocket(this.url);
    } catch (e) {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    ws.on("open", () => { this.connected = true; this.emit("connected"); });
    ws.on("message", (data) => this.handle(String(data)));
    ws.on("error", (err) => this.emit("log", `连接出错：${err.message}`));
    ws.on("close", () => {
      this.ws = null;
      const was = this.connected;
      this.connected = false;
      for (const [, p] of this.pending) p.reject(new Error("连接断了"));
      this.pending.clear();
      if (was) this.emit("disconnected");
      this.scheduleReconnect();
    });
  }

  scheduleReconnect() {
    if (this.closed || this.timer) return;
    this.timer = setTimeout(() => { this.timer = null; this.open(); }, 2000);
  }

  close() {
    this.closed = true;
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    if (this.ws) { try { this.ws.close(); } catch (e) { /* 已经关了 */ } this.ws = null; }
    this.connected = false;
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
      if (!this.ws || !this.connected) return reject(new Error("没连上 Switcher"));
      const id = this.nextID++;
      const timeout = setTimeout(() => { this.pending.delete(id); reject(new Error("回执超时")); }, 5000);
      this.pending.set(id, {
        resolve: (m) => { clearTimeout(timeout); resolve(m); },
        reject: (e) => { clearTimeout(timeout); reject(e); },
      });
      this.ws.send(JSON.stringify({ id, command }));
    });
  }
}
