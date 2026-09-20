#!/bin/bash
# 没装 Node 时的备用测试跑法：把 lib/tally.js 和 test/cases.js 去掉 import / export 后交给 macOS 自带的 JavaScriptCore（osascript -l JavaScript）。
# 断言用 node:assert/strict 的子集自己实现。有 Node 时直接 `npm test`。
set -euo pipefail
cd "$(dirname "$0")/.."
lib=com.plusmix.switcher.sdPlugin/lib/tally.js
tmp=$(mktemp -t switcher-sd-jxa).js
{
  cat <<'JS'
function deepEqual(a, b) { return JSON.stringify(a) === JSON.stringify(b); }
const assert = {
  equal(a, b, m) { if (a !== b) throw new Error((m || "equal") + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); },
  deepEqual(a, b, m) { if (!deepEqual(a, b)) throw new Error((m || "deepEqual") + ": " + JSON.stringify(a) + " != " + JSON.stringify(b)); },
  ok(v, m) { if (!v) throw new Error(m || "ok"); },
  match(s, re, m) { if (!re.test(s)) throw new Error((m || "match") + ": " + JSON.stringify(s) + " !~ " + re); },
};
JS
  sed -E 's/^export (const|function|class) /\1 /' "$lib"
  sed -E '/^import /d; s/^export (const|function|class) /\1 /' test/cases.js
  cat <<'JS'
let failed = 0;
for (const c of cases) {
  try { c.run(assert); console.log("ok   " + c.name); }
  catch (e) { failed++; console.log("FAIL " + c.name + "\n     " + e.message); }
}
console.log(failed === 0 ? "all " + cases.length + " passed" : failed + " failed");
if (failed) throw new Error(failed + " failed");
JS
} > "$tmp"
osascript -l JavaScript "$tmp" 2>&1
rc=$?
rm -f "$tmp"
exit $rc
