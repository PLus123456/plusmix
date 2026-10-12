// Switcher 的 Stream Deck 插件（官方 SDK @elgato/streamdeck）：按钮 = 命令，按钮颜色 = tally（PGM 红 / PVW 绿）。
// 对着本地 API（docs/api.md）：WS /api/v1/events 收快照，连接上发命令。连接参数（host / port / token）是全局设置，任一按钮的设置面板都能改。
import streamDeck, { SingletonAction } from "@elgato/streamdeck";
import { SwitcherClient } from "../lib/api-client.js";
import { commandFor, fpsFrom, keyStyle, pressFeedback, svgDataURI, svgKey } from "../lib/tally.js";

const PREFIX = "com.plusmix.switcher.";
const KINDS = ["cut", "auto", "slot", "preview", "program", "tally", "overlay", "record", "stream", "ftb"];

const client = new SwitcherClient();
/** 屏幕上的按钮：id → { action, kind, settings }。 */
const visible = new Map();

function paint(entry) {
  const style = keyStyle(entry.kind, client.snapshot, entry.settings, client.connected, fpsFrom(client.clock));
  entry.action.setImage(svgDataURI(svgKey(style))).catch(() => {});
}

function paintAll() {
  for (const entry of visible.values()) paint(entry);
}

class SwitcherAction extends SingletonAction {
  constructor(kind) {
    super();
    this.kind = kind;
    this.manifestId = PREFIX + kind;
  }

  async onWillAppear(ev) {
    visible.set(ev.action.id, { action: ev.action, kind: this.kind, settings: ev.payload.settings || {} });
    paint(visible.get(ev.action.id));
  }

  async onWillDisappear(ev) {
    visible.delete(ev.action.id);
  }

  async onDidReceiveSettings(ev) {
    const entry = visible.get(ev.action.id);
    if (entry) { entry.settings = ev.payload.settings || {}; paint(entry); }
  }

  async onKeyDown(ev) {
    const entry = visible.get(ev.action.id) || { action: ev.action, kind: this.kind, settings: ev.payload.settings || {} };
    const { command, error } = commandFor(this.kind, client.snapshot, entry.settings, fpsFrom(client.clock));
    let outcome;
    if (error) {
      outcome = { error };
    } else {
      try {
        outcome = { receipt: await client.send(command) };
      } catch (e) {
        outcome = { error: e.message };   // 被拒（例如没选输入的 Stinger 槽，提案 029）/ 没连上 / 超时
      }
    }
    const fb = pressFeedback(this.kind, outcome);
    if (fb.log) streamDeck.logger[fb.level](fb.log);
    if (fb.alert) await ev.action.showAlert();
  }
}

for (const kind of KINDS) streamDeck.actions.registerAction(new SwitcherAction(kind));

function applyGlobal(settings) {
  const s = settings || {};
  client.reconfigure({ host: s.host || "127.0.0.1", port: Number(s.port) || 8765, token: s.token || "" });
}

client.on("snapshot", paintAll);
client.on("connected", () => { streamDeck.logger.info(`已连上 ${client.url}`); paintAll(); });
client.on("disconnected", () => { streamDeck.logger.info("Switcher 断开，2 s 后重连"); paintAll(); });
client.on("log", (line) => streamDeck.logger.debug(line));
streamDeck.settings.onDidReceiveGlobalSettings((ev) => applyGlobal(ev.settings));

await streamDeck.connect();
applyGlobal(await streamDeck.settings.getGlobalSettings());
client.connect();
