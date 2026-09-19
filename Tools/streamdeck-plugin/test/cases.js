// 断言用例：node --test 和 JXA 共用。每个用例 run(assert) 只用 assert.equal / deepEqual / ok / match。
import { COLORS, classifyMessage, commandFor, fpsFrom, inputName, keyStyle, outputOf, svgDataURI, svgKey, tallyFor } from "../com.plusmix.switcher.sdPlugin/lib/tally.js";

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
    name: "classifyMessage",
    run(assert) {
      assert.equal(classifyMessage('{"type":"snapshot","sequence":1}').type, "snapshot");
      assert.equal(classifyMessage('{"type":"receipt","id":3}').message.id, 3);
      assert.equal(classifyMessage("{oops").type, "invalid");
      assert.equal(classifyMessage('{"x":1}').type, "unknown");
    },
  },
];
