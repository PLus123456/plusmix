// node --test：lib/tally.js 的纯函数。没有 node 时用 scripts/run-jxa.sh（同一批断言在 JavaScriptCore 里跑）。
import { test } from "node:test";
import assert from "node:assert/strict";
import { cases } from "./cases.js";

for (const c of cases) {
  test(c.name, () => c.run(assert));
}
