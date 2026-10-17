// 断言用例：node --test 和 JXA 共用。每个用例 run(assert) 只用 assert.equal / deepEqual / ok / match，同步跑完（JXA 没有事件循环）。
import { COLORS, classifyMessage, commandFor, fpsFrom, inputName, keyStyle, outputOf, pressFeedback, slotSublabel, svgDataURI, svgKey, tallyFor } from "../com.plusmix.switcher.sdPlugin/lib/tally.js";
import { SwitcherClient } from "../com.plusmix.switcher.sdPlugin/lib/api-client.js";

export const snapshot = {
  type: "snapshot",
  sequence: 5,
  state: {
    program: 1,
    preview: 2,
    transition: { type: "fade", durationTicks: 30, progress: 0, startTick: null },
    ftb: { on: false },
    inputs: [{ number: 1, name: "机位 1" }, { number: 2, name: "机位 2" }, { number: 3, name: "很长很长的输入名字超过九个字" }],
    overlays: [{ input: 3, on: true, animProgress: 1 }, { input: null, on: false, animProgress: 0 }, { input: 2, on: false, animProgress: 0 }, { input: null, on: false, animProgress: 0 }],
    outputs: [{ number: 1, kind: "record", name: "录制", enabled: true }, { number: 2, kind: "stream", name: "推流", enabled: false }, { number: 3, kind: "stream", name: "推流 2", enabled: true }],
  },
  tally: { "1": { program: true, preview: false }, "2": { program: false, preview: true }, "3": { program: true, preview: false } },
};

export const cases = [
  {
    name: "tallyFor 按快照的 tally 表；没有表时退回 program / preview",
    run(assert) {
      assert.deepEqual(tallyFor(snapshot, 1), { program: true, preview: false });
      assert.deepEqual(tallyFor(snapshot, 2), { program: false, preview: true });
      assert.deepEqual(tallyFor(snapshot, 3), { program: true, preview: false });
      assert.deepEqual(tallyFor(snapshot, 9), { program: false, preview: false });
      assert.deepEqual(tallyFor(null, 1), { program: false, preview: false });
      assert.deepEqual(tallyFor({ state: { program: 2, preview: 1 } }, 2), { program: true, preview: false });
    },
  },
  {
    name: "inputName / outputOf",
    run(assert) {
      assert.equal(inputName(snapshot, 2), "机位 2");
      assert.equal(inputName(snapshot, 9), "9");
      assert.equal(outputOf(snapshot, "stream").number, 2, "没给编号 = 该类里编号最小的");
      assert.equal(outputOf(snapshot, "stream", 3).name, "推流 2");
      assert.equal(outputOf(snapshot, "record", 2), null, "编号对不上种类");
    },
  },
  {
    name: "fpsFrom：frameDuration 的倒数，没时钟按 60",
    run(assert) {
      assert.equal(fpsFrom({ frameDuration: { numerator: 1001, denominator: 60000 } }), 60000 / 1001);
      assert.equal(fpsFrom({ frameDuration: { numerator: 1, denominator: 30 } }), 30);
      assert.equal(fpsFrom(null), 60);
    },
  },
  {
    name: "keyStyle：PGM 红、PVW 绿、都不在灰、未连接灰底",
    run(assert) {
      assert.equal(keyStyle("preview", snapshot, { input: "1" }, true).background, COLORS.program);
      assert.equal(keyStyle("preview", snapshot, { input: "2" }, true).background, COLORS.preview);
      assert.equal(keyStyle("program", snapshot, { input: "2" }, true).label, "PGM 2");
      const both = keyStyle("tally", { state: { program: 1, preview: 1 }, tally: { "1": { program: true, preview: true } } }, { input: 1 }, true);
      assert.equal(both.background, COLORS.program);
      assert.equal(both.border, COLORS.preview, "转场中：红底绿边");
      assert.equal(keyStyle("preview", snapshot, { input: "9" }, true).background, COLORS.off);
      assert.equal(keyStyle("preview", snapshot, { input: "1" }, false).background, COLORS.disconnected);
      assert.equal(keyStyle("preview", snapshot, { input: "1" }, false).sublabel, "未连接");
      assert.equal(keyStyle("overlay", snapshot, { channel: "1" }, true).background, COLORS.overlay);
      assert.equal(keyStyle("overlay", snapshot, { channel: "3" }, true).background, COLORS.off, "有输入但关着");
      assert.equal(keyStyle("record", snapshot, {}, true).background, COLORS.record);
      assert.equal(keyStyle("stream", snapshot, {}, true).background, COLORS.off, "第一路推流没开");
      assert.equal(keyStyle("stream", snapshot, { output: "3" }, true).background, COLORS.stream);
      assert.equal(keyStyle("ftb", snapshot, {}, true).background, COLORS.off);
      assert.equal(keyStyle("ftb", { state: { ftb: { on: true } } }, {}, true).border, COLORS.text);
      assert.equal(keyStyle("cut", snapshot, {}, true).label, "CUT");
      assert.equal(keyStyle("auto", snapshot, { mode: "fade", durationMs: "750" }, true).sublabel, "750 ms");
    },
  },
  {
    name: "commandFor：开关型按快照决定 on / off",
    run(assert) {
      assert.deepEqual(commandFor("cut", snapshot, {}, 60), { command: { cut: {} } });
      assert.deepEqual(commandFor("auto", snapshot, {}, 60), { command: { autoTransition: {} } });
      assert.deepEqual(commandFor("auto", snapshot, { mode: "fade", durationMs: "500" }, 60), { command: { fade: { durationTicks: 30 } } });
      assert.deepEqual(commandFor("auto", snapshot, { mode: "fade", durationMs: "1000" }, 60000 / 1001), { command: { fade: { durationTicks: 60 } } });
      assert.deepEqual(commandFor("preview", snapshot, { input: "3" }, 60), { command: { setPreview: { input: 3 } } });
      assert.deepEqual(commandFor("program", snapshot, { input: "3" }, 60), { command: { setProgram: { input: 3 } } });
      assert.ok(commandFor("preview", snapshot, {}, 60).error, "没设输入编号 → 错误");
      assert.deepEqual(commandFor("overlay", snapshot, { channel: "1" }, 60), { command: { overlay: { channel: 1, on: false } } }, "开着 → 关");
      assert.deepEqual(commandFor("overlay", snapshot, { channel: "2", input: "2" }, 60), { command: { overlay: { channel: 2, on: true, input: 2 } } }, "关着 → 开并换输入");
      assert.deepEqual(commandFor("overlay", snapshot, { channel: "3" }, 60), { command: { overlay: { channel: 3, on: true } } }, "关着、有输入、没设 → 直接开");
      assert.ok(commandFor("overlay", snapshot, { channel: "2" }, 60).error, "关着、没输入、没设 → 错误");
      assert.ok(commandFor("overlay", snapshot, { channel: "7" }, 60).error);
      assert.deepEqual(commandFor("record", snapshot, {}, 60), { command: { stopRecord: { output: 1 } } });
      assert.deepEqual(commandFor("stream", snapshot, {}, 60), { command: { startStream: { output: 2 } } });
      assert.deepEqual(commandFor("stream", snapshot, { output: "3" }, 60), { command: { stopStream: { output: 3 } } });
      assert.ok(commandFor("record", { state: { outputs: [] } }, {}, 60).error);
      assert.deepEqual(commandFor("ftb", snapshot, {}, 60), { command: { ftb: { on: true } } });
      assert.deepEqual(commandFor("ftb", { state: { ftb: { on: true } } }, {}, 60), { command: { ftb: { on: false } } });
      assert.ok(commandFor("nope", snapshot, {}, 60).error);
    },
  },
  {
    name: "转场 1–4（W5-M）：按下 = useTransitionSlot(n, start: true)（选中不执行可选）；颜色跟当前槽：当前槽蓝、执行中红、别的灰；字 = 槽号 + 效果与时长",
    run(assert) {
      const wipe = { direction: "leftToRight", softness: 0 };
      const noStinger = { cutAtTick: 0 };
      const slots = [
        { type: "fade", durationTicks: 30, wipe, stinger: noStinger },
        { type: "wipe", durationTicks: 60, wipe, stinger: noStinger },
        { type: "zoom", durationTicks: 60, wipe, stinger: noStinger },
        { type: "stinger", durationTicks: 60, wipe, stinger: noStinger },
      ];
      const idle = { state: { ...snapshot.state, transition: { type: "wipe", durationTicks: 60, progress: 0, slots, currentSlot: 2 } } };
      assert.deepEqual(commandFor("slot", idle, { slot: "2" }, 60), { command: { useTransitionSlot: { slot: 2, start: true } } });
      assert.deepEqual(commandFor("slot", idle, { slot: "3", mode: "select" }, 60), { command: { useTransitionSlot: { slot: 3, start: false } } }, "选中（不执行）");
      assert.deepEqual(commandFor("slot", idle, {}, 60), { command: { useTransitionSlot: { slot: 1, start: true } } }, "没设 = 转场 1");
      assert.ok(commandFor("slot", idle, { slot: "5" }, 60).error, "槽号要在 1–4");
      assert.deepEqual(commandFor("slot", null, { slot: "4" }, 60), { command: { useTransitionSlot: { slot: 4, start: true } } }, "没收到快照也能发（状态机自己判）");
      const current = keyStyle("slot", idle, { slot: "2" }, true, 60);
      assert.equal(current.background, COLORS.slotCurrent, "当前槽：蓝");
      assert.equal(current.label, "转场 2");
      assert.equal(current.sublabel, "Wipe → 1s");
      assert.equal(keyStyle("slot", idle, { slot: "1" }, true, 60).background, COLORS.action, "不是当前槽：灰");
      assert.equal(keyStyle("slot", idle, { slot: "1" }, true, 60).sublabel, "Fade 0.5s");
      assert.equal(keyStyle("slot", idle, { slot: "4" }, true, 60).sublabel, "未选输入", "Stinger 槽没选输入");
      const running = { state: { ...idle.state, transition: { ...idle.state.transition, startTick: 100, progress: 0.3 } } };
      assert.equal(keyStyle("slot", running, { slot: "2" }, true, 60).background, COLORS.program, "执行中：红");
      assert.equal(keyStyle("slot", running, { slot: "3" }, true, 60).background, COLORS.action);
      const loose = { state: { ...idle.state, transition: { type: "fade", durationTicks: 45, progress: 0, slots } } };
      assert.equal(keyStyle("slot", loose, { slot: "1" }, true, 60).background, COLORS.action, "当前那组不在槽里（没有 currentSlot）：四个都不亮");
      assert.equal(keyStyle("slot", snapshot, { slot: "2" }, true, 60).sublabel, "", "老版本的快照没有 slots：只写槽号");
      assert.equal(keyStyle("slot", null, { slot: "3" }, false).background, COLORS.disconnected);
      assert.equal(keyStyle("slot", null, { slot: "3" }, false).label, "转场 3");
    },
  },
  {
    name: "slotSublabel：按帧率换秒，放不下 9 个字时只写效果",
    run(assert) {
      const wipe = { direction: "diagonal", softness: 0 };
      assert.equal(slotSublabel({ type: "fade", durationTicks: 90, wipe, stinger: {} }, 60), "Fade 1.5s");
      assert.equal(slotSublabel({ type: "fade", durationTicks: 45, wipe, stinger: {} }, 60), "Fade", "Fade 0.75s 是 10 个字（按钮小字截到 9 个）：只写效果");
      assert.equal(slotSublabel({ type: "wipe", durationTicks: 45, wipe, stinger: {} }, 60), "Wipe ↘", "Wipe ↘ 0.75s 放不下：只写效果");
      assert.equal(slotSublabel({ type: "zoom", durationTicks: 60, wipe, stinger: {} }, 60000 / 1001), "Zoom 1s", "59.94：60 拍 ≈ 1 秒");
      assert.equal(slotSublabel({ type: "stinger", durationTicks: 60, wipe, stinger: { input: 3, cutAtTick: 10 } }, 60), "Stinger", "Stinger 1s 是 10 个字：只写效果");
      assert.equal(slotSublabel({ type: "cut", durationTicks: 0, wipe, stinger: {} }, 60), "Cut");
      assert.equal(slotSublabel(undefined, 60), "");
    },
  },
  {
    name: "svgKey / svgDataURI：SVG 文本转义、名字截断、base64",
    run(assert) {
      const style = keyStyle("preview", snapshot, { input: "3" }, true);
      const svg = svgKey(style);
      assert.match(svg, /^<svg xmlns="http:\/\/www.w3.org\/2000\/svg" width="144" height="144"/);
      assert.match(svg, /PVW 3/);
      assert.match(svg, /很长很长的输入名字…/, "超过 9 个字截断");
      const escaped = svgKey({ background: "#000", label: "A<B>&\"C\"", sublabel: "", border: null });
      assert.match(escaped, /A&lt;B&gt;&amp;&quot;C&quot;/);
      const uri = svgDataURI("<svg>é中</svg>");
      assert.equal(uri, "data:image/svg+xml;base64,PHN2Zz7DqeS4rTwvc3ZnPg==");
      assert.equal(svgDataURI("ab"), "data:image/svg+xml;base64,YWI=");
      assert.equal(svgDataURI("a"), "data:image/svg+xml;base64,YQ==");
      assert.equal(svgDataURI("abc"), "data:image/svg+xml;base64,YWJj");
    },
  },
  {
    name: "pressFeedback（W5-O / 提案 029）：命令被拒（WS error = HTTP 400 那一类，例如执行没选输入的 Stinger 槽）→ 闪警告；状态机忽略只记日志；成功不响",
    run(assert) {
      const rejected = pressFeedback("slot", { error: "转场 4 是 Stinger、还没选输入" });
      assert.equal(rejected.alert, true, "收到 400 → showAlert");
      assert.equal(rejected.level, "warn");
      assert.match(rejected.log, /转场 4 是 Stinger、还没选输入/);
      const ignored = pressFeedback("slot", { receipt: { applied: false } });
      assert.equal(ignored.alert, false, "已是目标状态：不闪");
      assert.equal(ignored.level, "info");
      assert.deepEqual(pressFeedback("slot", { receipt: { applied: true, sequence: 3 } }), { alert: false, level: null, log: null });
      assert.equal(pressFeedback("preview", { error: "没设输入编号" }).alert, true, "本地就判出来的错误同样闪");
    },
  },
  {
    name: "SwitcherClient 改连接设置（W2-C4 / D17）：旧 socket 后到的事件不碰新连接；不起第三条、不留没关的连接；旧连接没回执的命令作废、旧快照清掉",
    run(assert) {
      // 假 socket：事件由用例按顺序触发（真 ws 的 close 是异步的，旧连接的 close 会在新连接打开之后才到）
      const made = [];
      function FakeSocket(url) { this.url = url; this.handlers = {}; this.closeCalls = 0; this.closedByPeer = false; this.sent = []; made.push(this); }
      FakeSocket.prototype.on = function (event, f) { (this.handlers[event] = this.handlers[event] || []).push(f); return this; };
      FakeSocket.prototype.fire = function (event, arg) {
        if (event === "close") this.closedByPeer = true;
        for (const f of this.handlers[event] || []) f(arg);
      };
      FakeSocket.prototype.close = function () { this.closeCalls += 1; };
      FakeSocket.prototype.send = function (text) { this.sent.push(text); };
      const timers = [];
      const client = new SwitcherClient({
        WebSocket: FakeSocket,
        setTimer: (f, ms) => { timers.push({ f, ms, cleared: false, fired: false }); return timers.length - 1; },
        clearTimer: (id) => { if (timers[id]) timers[id].cleared = true; },
      });
      const events = [];
      const logs = [];
      client.on("connected", () => events.push("connected"));
      client.on("disconnected", () => events.push("disconnected"));
      client.on("log", (line) => logs.push(line));
      const open = () => made.filter((s) => s.closeCalls === 0 && !s.closedByPeer);   // 还开着的连接
      const reconnects = () => timers.filter((t) => t.ms === 2000 && !t.cleared && !t.fired);

      client.connect();
      const first = made[0];
      first.fire("open");
      first.fire("message", JSON.stringify({ type: "snapshot", sequence: 1, state: { program: 1, preview: 2 } }));
      assert.equal(client.connected, true);
      assert.equal(client.snapshot.sequence, 1);
      let oldError = null;
      client.send({ cut: {} }).catch((e) => { oldError = e.message; });   // 旧连接上一条还没回执的命令
      assert.equal(client.pending.size, 1);

      // 改地址：旧连接关掉、起第二条；旧连接上没回执的命令作废（不留给新连接）；旧快照清掉（别拿旧那台的状态算开关）
      client.reconfigure({ host: "127.0.0.2", port: 8765, token: "" });
      assert.equal(made.length, 2, "改设置：起第二条");
      const second = made[1];
      assert.equal(first.closeCalls, 1, "旧连接关掉");
      assert.equal(client.ws, second);
      assert.equal(client.pending.size, 0, "旧连接上没回执的命令作废");
      assert.equal(client.snapshot, null, "旧快照清掉");
      second.fire("open");
      assert.equal(client.connected, true);

      // 旧 socket 后到的事件（快照 / 出错 / close）一概不碰新连接：不收快照、不记日志、不当成断开、不排重连、不作废新连接的命令
      first.fire("message", JSON.stringify({ type: "snapshot", sequence: 99, state: {} }));
      assert.equal(client.snapshot, null, "旧连接的快照不收");
      first.fire("error", { message: "旧连接出错" });
      assert.equal(logs.length, 0, "旧连接出错不记成当前连接的");
      client.send({ cut: {} }).catch(() => {});
      assert.equal(client.pending.size, 1);
      first.fire("close");
      assert.equal(client.connected, true, "旧连接的 close 不把新连接当成断开");
      assert.equal(client.ws, second, "当前连接还是第二条");
      assert.equal(client.pending.size, 1, "新连接上的命令不被作废");
      assert.equal(reconnects().length, 0, "不排重连");
      assert.deepEqual(events, ["connected", "connected"], "没有 disconnected");
      assert.equal(second.sent.length, 1, "Cut 发到第二条上");
      assert.ok(JSON.parse(second.sent[0]).command.cut, "发的是 Cut");
      client.open();
      assert.equal(made.length, 2, "不出现第三条");
      assert.deepEqual(open(), [second], "只有第二条开着");

      // 改 token：第二条关掉、第三条起来；第二条后到的 close 同样不碰第三条
      client.reconfigure({ host: "127.0.0.2", port: 8765, token: "abc" });
      assert.equal(made.length, 3);
      const third = made[2];
      assert.equal(second.closeCalls, 1, "第二条关掉");
      assert.match(third.url, /token=abc/);
      third.fire("open");
      second.fire("close");
      assert.equal(client.connected, true);
      assert.equal(client.ws, third);
      assert.deepEqual(open(), [third], "只有第三条开着");

      // 当前连接自己断了：照旧 disconnected、2 s 后只重连一条
      third.fire("close");
      assert.equal(client.connected, false);
      assert.equal(events[events.length - 1], "disconnected");
      const retry = reconnects();
      assert.equal(retry.length, 1, "排一次重连");
      retry[0].fired = true;
      retry[0].f();
      assert.equal(made.length, 4, "重连起一条");
      assert.deepEqual(open(), [made[3]]);
      assert.equal(oldError === null || oldError === "连接断了", true, "旧命令按断开作废");
    },
  },
  {
    name: "classifyMessage",
    run(assert) {
      assert.equal(classifyMessage('{"type":"snapshot","sequence":1}').type, "snapshot");
      assert.equal(classifyMessage('{"type":"receipt","id":3}').message.id, 3);
      assert.equal(classifyMessage("{oops").type, "invalid");
      assert.equal(classifyMessage('{"x":1}').type, "unknown");
    },
  },
];
