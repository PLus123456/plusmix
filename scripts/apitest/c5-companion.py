#!/usr/bin/env python3
"""C5 的自动化版本（测试标准 §1 C5、§3 C5；W3-D prompt）：模拟 Companion 的模块对着兼容层端口跑六项，只用 Python 3 标准库。

  c5-companion.py --host 127.0.0.1 --tcp-port 8099 --http-port 8088 [--poll-ms 250] [--json out.json] [--md out.md] [--skip-http]

像 Companion 一样开三条 TCP 连接：
  functions   发 FUNCTION（和 PING）
  activators  SUBSCRIBE ACTS，收 ACTS OK 事件
  xml         每 poll-ms 发一次 XML，解析 `XML <长度>\\r\\n<正文>` 得到状态（active / preview / overlays / recording / streaming）
再开第四条订阅 TALLY（Companion 本身不用它，但 tally 灯设备用；C5 的"Tally 反馈"三种来源一起核对）。

六项（测试标准 §4 C5）：Cut / Fade / Overlay 1 开关 / Record 开关 / Stream 开关 / Tally 反馈；每项用 XML 轮询到的状态判定，
另加"HTTP"一项（GET /api/?Function=… 与 XML）不计入六项。任一项失败退出码 1；--json 写明细。
先起服务端：headless 的兼容层参数（G4 接线后）或 `SWITCHER_COMPAT_SERVE_SECONDS=600 swift test --package-path Packages/SwitcherControl --filter testC5_manual`。
"""
import argparse
import json
import socket
import sys
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET

# 上游协议规定的 XML 根元素名：Companion 的模块靠它识别文档（tcp.ts 里 startsWith / endsWith 的检查），改不了。
XML_ROOT = "vmix"


class Line:
    """\\r\\n 行协议客户端：一条后台线程收，行进队列；XML 的二进制段按长度收。"""

    def __init__(self, host, port, name):
        self.name = name
        self.sock = socket.create_connection((host, port), timeout=5)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.buf = b""
        self.lines = []
        self.xml_docs = []
        self.lock = threading.Condition()
        self.closed = False
        threading.Thread(target=self._reader, daemon=True, name=name).start()

    def _reader(self):
        while not self.closed:
            try:
                data = self.sock.recv(65536)
            except OSError:
                data = b""
            if not data:
                with self.lock:
                    self.closed = True
                    self.lock.notify_all()
                return
            with self.lock:
                self.buf += data
                self._drain()
                self.lock.notify_all()

    def _drain(self):
        while True:
            nl = self.buf.find(b"\n")
            if nl < 0:
                return
            line = self.buf[:nl].rstrip(b"\r").decode("utf-8", "replace")
            if line.startswith("XML "):
                try:
                    n = int(line[4:])
                except ValueError:
                    n = -1
                if n >= 0:
                    if len(self.buf) < nl + 1 + n:
                        return          # 正文还没到齐
                    body = self.buf[nl + 1:nl + 1 + n]
                    self.buf = self.buf[nl + 1 + n:]
                    self.xml_docs.append(body.decode("utf-8", "replace"))
                    continue
            self.buf = self.buf[nl + 1:]
            self.lines.append(line)

    def send(self, line):
        self.sock.sendall((line + "\r\n").encode("utf-8"))

    def readline(self, timeout=5.0):
        deadline = time.time() + timeout
        with self.lock:
            while not self.lines:
                left = deadline - time.time()
                if left <= 0 or self.closed:
                    return None
                self.lock.wait(left)
            return self.lines.pop(0)

    def read_xml(self, timeout=5.0):
        deadline = time.time() + timeout
        with self.lock:
            while not self.xml_docs:
                left = deadline - time.time()
                if left <= 0 or self.closed:
                    return None
                self.lock.wait(left)
            return self.xml_docs.pop(0)

    def take_lines(self):
        with self.lock:
            out, self.lines = self.lines, []
            return out

    def close(self):
        self.closed = True
        try:
            self.sock.close()
        except OSError:
            pass


class Status:
    """XML 解析出来的状态（Companion data.ts 的子集）。"""

    def __init__(self, text):
        root = ET.fromstring(text)
        if root.tag != XML_ROOT:
            raise ValueError("XML 根元素是 %s" % root.tag)
        self.version = root.findtext("version")
        self.active = int(root.findtext("active"))
        self.preview = int(root.findtext("preview"))
        self.recording = (root.findtext("recording") or "").strip() == "True"
        self.streaming = (root.findtext("streaming") or "").strip() == "True"
        self.ftb = (root.findtext("fadeToBlack") or "").strip() == "True"
        self.overlays = {}
        for o in root.find("overlays"):
            n = int(o.get("number"))
            self.overlays[n] = int(o.text) if (o.text or "").strip() else None
        self.inputs = {}
        for i in root.find("inputs"):
            self.inputs[int(i.get("number"))] = dict(i.attrib)
        # Companion 的 tally 判定：program = active 或某个叠加通道上的输入；preview = preview
        self.program_set = {self.active} | {v for v in self.overlays.values() if v is not None}


class Poller(threading.Thread):
    """xml 连接：每 poll-ms 发一次 XML，记最近状态。"""

    def __init__(self, conn, poll_ms):
        super().__init__(daemon=True, name="xml-poll")
        self.conn = conn
        self.poll = poll_ms / 1000.0
        self.latest = None
        self.count = 0
        self.errors = []
        self.stop = False

    def run(self):
        while not self.stop:
            t = time.time()
            try:
                self.conn.send("XML")
                doc = self.conn.read_xml(timeout=5)
                if doc is None:
                    self.errors.append("XML 超时")
                else:
                    self.latest = Status(doc)
                    self.count += 1
            except Exception as e:      # noqa: BLE001
                self.errors.append(str(e))
            time.sleep(max(0.0, self.poll - (time.time() - t)))

    def wait_for(self, predicate, timeout=3.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            s = self.latest
            if s is not None and predicate(s):
                return s
            time.sleep(0.02)
        return None


class Item:
    def __init__(self, name):
        self.name = name
        self.passed = False
        self.detail = ""
        self.t0 = time.time()
        self.ms = 0.0

    def done(self, passed, detail):
        self.passed = passed
        self.detail = detail
        self.ms = (time.time() - self.t0) * 1000
        return self


def expect_ok(conn, function, item_notes):
    conn.send("FUNCTION " + function)
    resp = conn.readline(timeout=5)
    item_notes.append("%s → %s" % (function, resp))
    return resp is not None and resp.startswith("FUNCTION OK")


def run(args):
    items = []
    notes = []
    functions = Line(args.host, args.tcp_port, "functions")
    activators = Line(args.host, args.tcp_port, "activators")
    xml = Line(args.host, args.tcp_port, "xml")
    tally = Line(args.host, args.tcp_port, "tally")
    for c in (functions, activators, xml, tally):
        greeting = c.readline(timeout=5)
        notes.append("%s 问候：%s" % (c.name, greeting))
        if not greeting or not greeting.startswith("VERSION OK"):
            items.append(Item("连接").done(False, "%s 没收到 VERSION OK 问候：%r" % (c.name, greeting)))
            return items, notes
    activators.send("SUBSCRIBE ACTS")
    notes.append("SUBSCRIBE ACTS → %s" % activators.readline())
    # Companion 连上后问一串 BusXSolo
    for b in "ABCDEFG":
        activators.send("ACTS Bus%sSolo" % b)
    for _ in range(7):
        activators.readline(timeout=2)
    tally.send("SUBSCRIBE TALLY")
    notes.append("SUBSCRIBE TALLY → %s / %s" % (tally.readline(), tally.readline()))
    poller = Poller(xml, args.poll_ms)
    poller.start()
    first = poller.wait_for(lambda s: True, timeout=5)
    if first is None:
        items.append(Item("连接").done(False, "XML 轮询没拿到状态：%s" % poller.errors[-3:]))
        return items, notes
    notes.append("版本 %s，%d 路输入，PGM %d，PVW %d" % (first.version, len(first.inputs), first.active, first.preview))
    if len(first.inputs) < 3:
        items.append(Item("连接").done(False, "至少要 3 路输入，现在 %d 路" % len(first.inputs)))
        return items, notes

    # 1. Cut
    it = Item("Cut")
    a, p = first.active, first.preview
    if a == p or p == 0:
        target = next(n for n in sorted(first.inputs) if n != a)
        expect_ok(functions, "PreviewInput Input=%d" % target, notes)
        poller.wait_for(lambda s: s.preview == target)
        p = target
    ok = expect_ok(functions, "Cut", notes)
    after = poller.wait_for(lambda s: s.active == p and s.preview == a)
    acts = activators.take_lines()
    acts_ok = ("ACTS OK Input %d 1" % p) in acts and ("ACTS OK Input %d 0" % a) in acts
    items.append(it.done(ok and after is not None and acts_ok,
                         "PGM %d→%d PVW %d→%d；ACTS %s" % (a, after.active if after else -1, p, after.preview if after else -1, "对" if acts_ok else acts)))

    # 2. Fade
    it = Item("Fade")
    cur = poller.latest
    a, p = cur.active, cur.preview
    ok = expect_ok(functions, "Fade Duration=500", notes)
    swapped = poller.wait_for(lambda s: s.active == p and s.preview == a, timeout=4)
    items.append(it.done(ok and swapped is not None, "500 ms 后 PGM %d→%d" % (a, swapped.active if swapped else -1)))

    # 3. Overlay 1 开关
    it = Item("Overlay 1 开关")
    cur = poller.latest
    x = next(n for n in sorted(cur.inputs) if n not in (cur.active, cur.preview))
    ok1 = expect_ok(functions, "OverlayInput1 Input=%d" % x, notes)
    on = poller.wait_for(lambda s: s.overlays.get(1) == x)
    ok2 = expect_ok(functions, "OverlayInput1 Input=%d" % x, notes)
    off = poller.wait_for(lambda s: s.overlays.get(1) is None)
    ok3 = expect_ok(functions, "OverlayInput1In Input=%d" % x, notes)
    on2 = poller.wait_for(lambda s: s.overlays.get(1) == x)
    ok4 = expect_ok(functions, "OverlayInput1Off", notes)
    off2 = poller.wait_for(lambda s: s.overlays.get(1) is None)
    acts = activators.take_lines()
    acts_ok = ("ACTS OK Overlay1 %d 1" % x) in acts and ("ACTS OK Overlay1 %d 0" % x) in acts
    items.append(it.done(all([ok1, ok2, ok3, ok4]) and None not in (on, off, on2, off2) and acts_ok,
                         "输入 %d：开→关→In→Off 各自在 XML 里生效；ACTS %s" % (x, "对" if acts_ok else acts)))

    # 4. Record 开关
    it = Item("Record 开关")
    ok1 = expect_ok(functions, "StartStopRecording", notes)
    on = poller.wait_for(lambda s: s.recording)
    ok2 = expect_ok(functions, "StartStopRecording", notes)
    off = poller.wait_for(lambda s: not s.recording)
    acts = activators.take_lines()
    acts_ok = "ACTS OK Recording 1" in acts and "ACTS OK Recording 0" in acts
    items.append(it.done(ok1 and ok2 and on is not None and off is not None and acts_ok, "recording True→False；ACTS %s" % ("对" if acts_ok else acts)))

    # 5. Stream 开关
    it = Item("Stream 开关")
    ok1 = expect_ok(functions, "StartStopStreaming", notes)
    on = poller.wait_for(lambda s: s.streaming)
    ok2 = expect_ok(functions, "StartStopStreaming", notes)
    off = poller.wait_for(lambda s: not s.streaming)
    acts = activators.take_lines()
    acts_ok = "ACTS OK Streaming 1" in acts and "ACTS OK Streaming 0" in acts
    items.append(it.done(ok1 and ok2 and on is not None and off is not None and acts_ok, "streaming True→False；ACTS %s" % ("对" if acts_ok else acts)))

    # 6. Tally 反馈：换 PVW 后，XML（Companion 的按钮色）/ TALLY 命令 / TALLY 订阅三处一致
    it = Item("Tally 反馈")
    cur = poller.latest
    y = next(n for n in sorted(cur.inputs) if n not in (cur.active, cur.preview))
    tally.take_lines()
    ok = expect_ok(functions, "PreviewInput Input=%d" % y, notes)
    st = poller.wait_for(lambda s: s.preview == y)
    functions.send("TALLY")
    tally_cmd = functions.readline()
    pushed = [l for l in tally.take_lines() if l.startswith("TALLY OK ")]
    digits = tally_cmd[9:] if tally_cmd and tally_cmd.startswith("TALLY OK ") else ""
    checks = []
    if st is not None and digits:
        for n in sorted(st.inputs):
            d = digits[n - 1] if n - 1 < len(digits) else "?"
            want = "1" if n in st.program_set else ("2" if n == st.preview else "0")
            checks.append(d == want)
    pushed_ok = bool(pushed) and pushed[-1][9:] == digits
    items.append(it.done(ok and st is not None and checks and all(checks) and pushed_ok,
                         "PVW→%d；TALLY %s；XML 推出的 %d 位全对；订阅推送 %s" % (y, digits, len(checks), "一致" if pushed_ok else pushed)))

    # HTTP（不计入六项）
    if not args.skip_http:
        it = Item("HTTP（附加）")
        base = "http://%s:%d" % (args.host, args.http_port)
        try:
            cur = poller.latest
            z = next(n for n in sorted(cur.inputs) if n != cur.preview and n != cur.active)
            with urllib.request.urlopen(base + "/api/?Function=PreviewInput&Input=%d" % z, timeout=5) as r:
                code1, body1 = r.status, r.read().decode()
            st = poller.wait_for(lambda s: s.preview == z)
            with urllib.request.urlopen(base + "/api", timeout=5) as r:
                xml_ok = Status(r.read().decode()).preview == z
            try:
                urllib.request.urlopen(base + "/api/?Function=Merge", timeout=5)
                code2 = 200
            except urllib.error.HTTPError as e:
                code2 = e.code
            items.append(it.done(code1 == 200 and st is not None and xml_ok and code2 == 501,
                                 "PreviewInput → %d %s；GET /api 的 preview 一致 %s；Merge → %d" % (code1, body1, xml_ok, code2)))
        except Exception as e:      # noqa: BLE001
            items.append(it.done(False, "HTTP 出错：%s" % e))

    # 收尾：PING 两条命令连接都活着
    functions.send("PING")
    activators.send("PING")
    notes.append("PING → %s / %s" % (functions.readline(), activators.readline()))
    poller.stop = True
    notes.append("XML 轮询 %d 次，错误 %d" % (poller.count, len(poller.errors)))
    for c in (functions, activators, xml, tally):
        c.close()
    return items, notes


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--tcp-port", type=int, default=8099)
    ap.add_argument("--http-port", type=int, default=8088)
    ap.add_argument("--poll-ms", type=int, default=250)
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--skip-http", action="store_true")
    args = ap.parse_args()
    try:
        items, notes = run(args)
    except OSError as e:
        print("连不上 %s:%d：%s" % (args.host, args.tcp_port, e))
        sys.exit(2)
    six = [i for i in items if not i.name.startswith("HTTP") and i.name != "连接"]
    passed = all(i.passed for i in items) and len(six) == 6
    lines = ["| 项 | 通过 | 说明 | 用时 |", "|---|---|---|---|"]
    for i in items:
        lines.append("| %s | %s | %s | %.0f ms |" % (i.name, "✅" if i.passed else "❌", i.detail.replace("|", "\\|"), i.ms))
    md = "\n".join(lines)
    print(md)
    print()
    for n in notes:
        print("  " + n)
    print("\nC5 %s：%d/6 项通过" % ("通过" if passed else "未通过", sum(1 for i in six if i.passed)))
    if args.md:
        with open(args.md, "w") as f:
            f.write(md + "\n")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"passed": passed, "items": [vars(i) for i in items], "notes": notes}, f, ensure_ascii=False, indent=2)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
