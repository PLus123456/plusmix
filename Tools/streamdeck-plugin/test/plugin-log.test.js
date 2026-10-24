// node 专用：bin/plugin.js 一 import 就要 @elgato/streamdeck（测试里不装），只能读源码查——写日志的地方不许拿 client.url（带 ?token=，Codex 10-24 审计 NS11）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

test("NS11：plugin.js 的日志不写 client.url，连上只写 client.endpoint（host:port）", () => {
  const src = readFileSync(new URL("../com.plusmix.switcher.sdPlugin/bin/plugin.js", import.meta.url), "utf8");
  const logLines = src.split("\n").filter((line) => /logger\.\w+\(/.test(line));
  assert.ok(logLines.length > 0, "plugin.js 里应有日志调用");
  for (const line of logLines) assert.ok(!/client\.url/.test(line), line);
  assert.match(src, /已连上 \$\{client\.endpoint\}/);
});
