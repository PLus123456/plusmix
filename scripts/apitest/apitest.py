#!/usr/bin/env python3
"""C 系列测试的客户端（测试标准 §1 C1–C4、§3；W2-C prompt）。只用 Python 3 标准库：自带一个 RFC 6455 文本帧客户端。

  apitest.py run      --url http://127.0.0.1:8765 --out session.json [--c1-count 50] [--c1-period 1.0] [--c1-phase 0.5]
                      [--scenario-period 5.0] [--c4-seconds 60] [--c4-rate 100] [--c4-clients 2] [--max-seconds 660]
                      连上 WS 记录全部 snapshot / stats（本机 host time 收到时刻），按计划发 C1 的 cut 和 C4 的带序号命令，
                      服务端关掉 WS（headless 跑完）或到 --max-seconds 后把会话写成 JSON。
  apitest.py evaluate --session session.json --frames frames.json --fps 60 [--show show.json] [--out report.md] [--json summary.json]
                      frames.json = `frameprobe frames out.mov --out frames.json`；算 C1 / C2 / C3 / C4，写 Markdown，任一硬指标不过退出码 1。
                      画面里烧的是调色板序号 patternID（合成源默认 (编号 − 1) mod 16），--show 给节目文件就按它精确映射回输入编号。
  apitest.py scenario --out scenario.json --seconds 600 --fps 60 --inputs 8 [--cut-every 5] [--fade-every 60] [--fade-ticks 30]
                      C3 用的场景：每 cut-every 秒切一次（每 fade-every 秒那次用 Fade），切完把 PVW 推到下一路。

时间：客户端用 ctypes 调 mach_absolute_time()，和服务端的 host time 同一个钟（不是 time.monotonic()：本机实测它含睡眠时间，差几十小时）。
"""
import argparse
import base64
import ctypes
import http.client
import json
import os
import random
import socket
import struct
import sys
import threading
import time
import urllib.parse

# ---------- host time ----------

_libc = ctypes.CDLL(None)
_libc.mach_absolute_time.restype = ctypes.c_uint64


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


def host_now():
    """mach_absolute_time 原始 tick（与服务端 HostTime 同一时基）。"""
    return int(_libc.mach_absolute_time())


def host_timebase():
    tb = _Timebase()
    _libc.mach_timebase_info(ctypes.byref(tb))
    return tb.numer, tb.denom


TB_NUMER, TB_DENOM = host_timebase()


def ticks_to_ms(ticks):
    return ticks * TB_NUMER / TB_DENOM / 1e6


def ns_to_ticks(ns):
    return int(ns * TB_DENOM / TB_NUMER)


# ---------- WebSocket 客户端（RFC 6455，文本帧） ----------

class WebSocket:
    def __init__(self, url, timeout=5.0):
        u = urllib.parse.urlparse(url)
        host, port = u.hostname, u.port or (443 if u.scheme == "wss" else 80)
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("握手时连接被关")
            buf += chunk
        head, _, rest = buf.partition(b"\r\n\r\n")
        status = head.split(b"\r\n")[0].decode(errors="replace")
        if " 101 " not in status:
            raise ConnectionError(f"WS 升级失败：{status}")
        self.buf = bytearray(rest)
        self.closed = False
        self._fragments = []
        self._lock = threading.Lock()

    def _read_exact(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("连接被关")
            self.buf += chunk
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def recv_text(self):
        """返回 (text, received_at_hosttime)；连接关闭返回 (None, t)。"""
        while True:
            b1, b2 = self._read_exact(2)
            fin, opcode = b1 & 0x80, b1 & 0x0F
            masked, length = b2 & 0x80, b2 & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if masked else None
            payload = self._read_exact(length)
            received_at = host_now()
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x8:
                self.closed = True
                try:
                    self._send_frame(0x8, payload[:2])
                except OSError:
                    pass
                return None, received_at
            if opcode == 0x9:
                self._send_frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            if opcode in (0x1, 0x2, 0x0):
                self._fragments.append(payload)
                if fin:
                    data = b"".join(self._fragments)
                    self._fragments = []
                    return data.decode("utf-8", errors="replace"), received_at
                continue

    def _send_frame(self, opcode, payload):
        header = bytearray([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack("!H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack("!Q", n)
        mask = os.urandom(4)
        header += mask
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self._lock:
            self.sock.sendall(bytes(header) + body)

    def send_text(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def close(self):
        if not self.closed:
            self.closed = True
            try:
                self._send_frame(0x8, struct.pack("!H", 1000))
            except OSError:
                pass
        try:
            self.sock.close()
        except OSError:
            pass


# ---------- HTTP ----------

class API:
    def __init__(self, base_url, token=None):
        u = urllib.parse.urlparse(base_url)
        self.host, self.port = u.hostname, u.port or 80
        self.base_path = u.path.rstrip("/")
        self.token = token
        self.conn = None

    def _headers(self):
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def _connection(self):
        if self.conn is None:
            self.conn = http.client.HTTPConnection(self.host, self.port, timeout=10)
            self.conn.connect()
            self.conn.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return self.conn

    def request(self, method, path, body=None):
        """返回 (status, json, send_hosttime, recv_hosttime)。连接断了重连一次。"""
        for attempt in range(2):
            try:
                c = self._connection()
                data = json.dumps(body).encode() if body is not None else None
                t_send = host_now()
                c.request(method, self.base_path + path, body=data, headers=self._headers())
                r = c.getresponse()
                raw = r.read()
                t_recv = host_now()
                try:
                    obj = json.loads(raw) if raw else None
                except ValueError:
                    obj = {"_raw": raw.decode(errors="replace")}
                return r.status, obj, t_send, t_recv
            except (http.client.HTTPException, OSError):
                self.conn = None
                if attempt == 1:
                    raise

    def state(self):
        st, obj, _, _ = self.request("GET", "/api/v1/state")
        if st != 200:
            raise RuntimeError(f"GET state → {st} {obj}")
        return obj

    def command(self, command):
        return self.request("POST", "/api/v1/command", {"command": command})

    def ws_url(self):
        q = f"?token={self.token}" if self.token else ""
        return f"ws://{self.host}:{self.port}{self.base_path}/api/v1/events{q}"


def wait_for_api(api, seconds=30):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            return api.state()
        except Exception:
            time.sleep(0.2)
    raise RuntimeError("API 没起来")


# ---------- run ----------

class Listener(threading.Thread):
    """一条 WS 连接，把 snapshot / stats 记下来。"""

    def __init__(self, url):
        super().__init__(daemon=True)
        self.url = url
        self.hello = None
        self.snapshots = []
        self.stats = []
        self.other = []
        self.error = None
        self.ready = threading.Event()
        self.done = threading.Event()
        self.ws = None

    def run(self):
        try:
            self.ws = WebSocket(self.url)
            while True:
                text, at = self.ws.recv_text()
                if text is None:
                    break
                m = json.loads(text)
                t = m.get("type")
                if t == "hello":
                    self.hello = m
                    self.hello_at = at
                    self.ready.set()
                elif t == "snapshot":
                    s = m["state"]
                    self.snapshots.append({
                        "recv": at, "sentAt": m.get("sentAt"), "publishedAt": m.get("publishedAt"), "tick": m["tick"], "tickTime": m.get("tickTime"),
                        "sequence": m["sequence"], "program": s["program"], "preview": s["preview"],
                        "transitionActive": (s["transition"]["progress"] > 0) or (s["transition"].get("startTick") is not None),
                        "tally": m["tally"], "bytes": len(text),
                        "inputNames": {str(i["number"]): i["name"] for i in s["inputs"]},
                    })
                elif t == "stats":
                    self.stats.append({"recv": at, "tick": m["stats"]["tick"], "ts": m["stats"]["ts"]})
                else:
                    self.other.append(m)
        except Exception as e:  # noqa: BLE001
            self.error = repr(e)
        finally:
            self.ready.set()
            self.done.set()


def cmd_run(a):
    api = API(a.url, a.token)
    state0 = wait_for_api(api)
    print(f"API 在线：sequence {state0['sequence']} tick {state0['tick']} program {state0['state']['program']}", flush=True)
    listener = Listener(api.ws_url())
    listener.start()
    listener.ready.wait(10)
    if listener.hello is None:
        raise RuntimeError(f"没收到 hello：{listener.error}")
    hello = listener.hello
    clock = hello.get("clock")
    if clock is None:
        # 引擎还没起时钟：等到 state 里有
        for _ in range(100):
            st = api.state()
            if st.get("clock"):
                clock = st["clock"]
                break
            time.sleep(0.1)
    if clock is None:
        raise RuntimeError("API 没有时钟（引擎没起？）")
    t0 = clock["t0"]
    fd = clock["frameDuration"]
    frame_ticks = ns_to_ticks(fd["numerator"] * 1e9 / fd["denominator"])
    print(f"时钟：t0 {t0}，帧 {fd['numerator']}/{fd['denominator']} s = {ticks_to_ms(frame_ticks):.3f} ms；hello 时基 {hello['timebase']}", flush=True)
    session = {
        "startedAt": host_now(), "url": a.url, "clock": clock, "timebase": {"numer": TB_NUMER, "denom": TB_DENOM},
        "hello": hello, "c1": [], "c4": None, "params": vars(a),
    }
    if host_now() < t0:
        time.sleep(ticks_to_ms(t0 - host_now()) / 1e3 + 0.5)

    # ---- C1：在避开场景切换的相位发 cut ----
    if a.c1_count > 0:
        print(f"C1：{a.c1_count} 次 cut，周期 {a.c1_period} s，相位避开场景切换（场景周期 {a.scenario_period} s）", flush=True)
        k = 0
        while k < a.c1_count:
            # 下一个发送时刻：相对 t0 的秒数 = n × c1_period + c1_phase，且距场景切换点 ≥ 0.4 s
            now_s = ticks_to_ms(host_now() - t0) / 1e3
            n = int(now_s // a.c1_period) + 1
            while True:
                target = n * a.c1_period + a.c1_phase
                if a.scenario_period <= 0 or abs((target % a.scenario_period) - 0) >= 0.4 and abs((target % a.scenario_period) - a.scenario_period) >= 0.4:
                    break
                n += 1
            wait = target - ticks_to_ms(host_now() - t0) / 1e3
            if wait > 0:
                time.sleep(wait)
            st = api.state()
            prev = st["state"]["program"]
            # 场景脚本自己也在转 PVW，可能已把 PVW 转到和 PGM 同一路（cut 就看不出变化）；先把 PVW 明确指到另一路
            numbers = [i["number"] for i in st["state"]["inputs"]]
            expected = next((n for n in numbers if n != prev), prev)
            if st["state"]["preview"] != expected:
                api.command({"setPreview": {"input": expected}})
                time.sleep(0.05)
            status, obj, t_send, t_recv = api.command({"cut": {}})
            rec = {"k": k, "send": t_send, "recv": t_recv, "rtt_ticks": t_recv - t_send, "status": status,
                   "prevProgram": prev, "expectedProgram": expected}
            if status == 200:
                rec.update({"sequence": obj["sequence"], "appliedTick": obj["appliedTick"], "appliedTickTime": obj.get("appliedTickTime"),
                            "applied": obj.get("applied")})
            else:
                rec["error"] = obj
            session["c1"].append(rec)
            k += 1
        ok = sum(1 for r in session["c1"] if r["status"] == 200)
        print(f"C1：发完，{ok}/{a.c1_count} 条 200；RTT 中位 {sorted(ticks_to_ms(r['rtt_ticks']) for r in session['c1'])[len(session['c1']) // 2]:.3f} ms", flush=True)

    # ---- C4：每客户端每秒 rate 条带序号的 renameInput，clients 个并发 ----
    if a.c4_seconds > 0:
        print(f"C4：{a.c4_clients} 个客户端 × {a.c4_rate}/s × {a.c4_seconds} s", flush=True)
        before = api.state()
        results = []
        threads = []

        def client(idx):
            my = API(a.url, a.token)
            inp = idx + 1
            receipts, errors = [], []
            period = 1.0 / a.c4_rate
            total = int(a.c4_rate * a.c4_seconds)
            start = time.perf_counter()
            for k in range(1, total + 1):
                target = start + (k - 1) * period
                delay = target - time.perf_counter()
                if delay > 0:
                    time.sleep(delay)
                try:
                    status, obj, t_send, t_recv = my.command({"renameInput": {"input": inp, "name": f"c{idx}-{k}"}})
                except Exception as e:  # noqa: BLE001
                    errors.append({"k": k, "error": repr(e)})
                    continue
                if status == 200:
                    receipts.append({"k": k, "sequence": obj["sequence"], "appliedTick": obj["appliedTick"], "applied": obj.get("applied"),
                                     "rtt_ticks": t_recv - t_send})
                else:
                    errors.append({"k": k, "status": status, "body": obj})
            results.append({"client": idx, "input": inp, "total": total, "receipts": receipts, "errors": errors,
                            "elapsed": time.perf_counter() - start})

        for i in range(a.c4_clients):
            t = threading.Thread(target=client, args=(i,), daemon=True)
            threads.append(t)
            t.start()
        for t in threads:
            t.join()
        time.sleep(0.5)
        after = api.state()
        results.sort(key=lambda r: r["client"])
        session["c4"] = {"clients": results, "sequenceBefore": before["sequence"], "sequenceAfter": after["sequence"],
                         "finalNames": {str(i["number"]): i["name"] for i in after["state"]["inputs"]}}
        n_ok = sum(len(r["receipts"]) for r in results)
        n_err = sum(len(r["errors"]) for r in results)
        print(f"C4：{n_ok} 条回执，{n_err} 条出错，sequence {before['sequence']} → {after['sequence']}", flush=True)

    # ---- 等 headless 跑完（服务端关 WS）或到上限 ----
    print("等待运行结束（服务端关 WS）……", flush=True)
    remaining = a.max_seconds - ticks_to_ms(host_now() - session["startedAt"]) / 1e3
    listener.done.wait(max(remaining, 1))
    if not listener.done.is_set():
        print("到 --max-seconds 上限，主动断开", flush=True)
        try:
            listener.ws.close()
        except Exception:  # noqa: BLE001
            pass
        listener.done.wait(5)
    session["snapshots"] = listener.snapshots
    session["stats"] = listener.stats
    session["listenerError"] = listener.error
    session["endedAt"] = host_now()
    with open(a.out, "w") as f:
        json.dump(session, f)
    print(f"会话写到 {a.out}：{len(listener.snapshots)} 条快照，{len(listener.stats)} 条 stats，WS 结束原因 {listener.error or '服务端关闭'}", flush=True)


# ---------- evaluate ----------

def percentile(xs, p):
    if not xs:
        return None
    s = sorted(xs)
    i = min(len(s) - 1, max(0, int(round(p * len(s) + 0.5)) - 1))
    return s[i]


def cmd_evaluate(a):
    with open(a.session) as f:
        session = json.load(f)
    tb = session["timebase"]
    numer, denom = tb["numer"], tb["denom"]

    def ms(ticks):
        return ticks * numer / denom / 1e6

    clock = session["clock"]
    t0 = clock["t0"]
    fd = clock["frameDuration"]
    fps = a.fps or fd["denominator"] / fd["numerator"]
    frame_ms = 1e3 / fps

    def tick_time(tick):
        return t0 + int(tick * fd["numerator"] * 1e9 / fd["denominator"] * denom / numer)

    def tick_at(t):
        # 最大的 n 使 tick_time(n) ≤ t
        n = int(ms(t - t0) / frame_ms)
        while tick_time(n + 1) <= t:
            n += 1
        while n > 0 and tick_time(n) > t:
            n -= 1
        return n

    snapshots = sorted(session["snapshots"], key=lambda s: (s["tick"], s["sequence"]))
    report = {"fps": fps, "frame_ms": frame_ms}
    lines = ["# C 系列（scripts/apitest）", ""]
    hard_fail = False

    # ---- 帧 ----
    # 画面里的输入 ID 是调色板序号：SyntheticVideoInput 用 settings.patternID，没设就 (编号 − 1) mod 16（TestKit）。映射回输入编号。
    id_to_input = {}
    if a.show:
        with open(a.show) as f:
            show = json.load(f)
        for inp in show["inputs"]:
            pid = (inp.get("source", {}).get("synthetic", {}).get("settings", {}) or {}).get("patternID")
            if pid is None:
                pid = (inp["number"] - 1) % 16
            id_to_input[pid] = inp["number"]
    else:
        id_to_input = {i: i + 1 for i in range(16)}
    frames = None
    if a.frames:
        with open(a.frames) as f:
            fr = json.load(f)
        frames = fr["frames"]
        for fobj in frames:
            pid = fobj.get("inputID")     # 解不出时 JSON 里没有这个键
            fobj["input"] = id_to_input.get(pid) if pid is not None else None
        report["frames"] = {"count": fr["frameCount"], "truncated": fr["truncated"], "durationSeconds": fr["info"]["durationSeconds"]}
        # 帧 → 拍：按 pts（文件时间线原点 = 第 0 拍），并核对 index
        pts_mismatch = 0
        for fobj in frames:
            fobj["tick"] = int(round(fobj["ptsSeconds"] * fps))
            if fobj["tick"] != fobj["index"]:
                pts_mismatch += 1
        report["frames"]["ptsIndexMismatch"] = pts_mismatch

    # ---- C1 ----
    c1 = session.get("c1") or []
    if c1:
        rows = []
        n_pass = 0
        n_pic_matches_receipt = 0
        n_missing = 0
        for r in c1:
            row = {"k": r["k"], "rtt_ms": ms(r["rtt_ticks"]), "status": r["status"]}
            if r["status"] != 200:
                row["error"] = r.get("error")
                rows.append(row)
                continue
            send_tick = tick_at(r["send"])
            row["sendTick"] = send_tick
            row["appliedTick"] = r["appliedTick"]
            row["applied"] = r.get("applied")
            row["receipt_ms"] = ms(tick_time(r["appliedTick"]) - r["send"])
            eff = None
            if frames is not None:
                # 画面上生效的拍：从 sendTick − 1 起，第一个 inputID == 期望 PGM 的帧（之前那帧不是它）
                lo = max(0, send_tick - 1)
                prev_id = None
                for fobj in frames:
                    if fobj["tick"] < lo - 1:
                        continue
                    if fobj["tick"] > send_tick + 6:
                        break
                    if fobj["input"] == r["expectedProgram"] and prev_id != r["expectedProgram"] and fobj["tick"] >= lo:
                        eff = fobj["tick"]
                        break
                    prev_id = fobj["input"]
                if eff is None:
                    n_missing += 1
                    row["pictureTick"] = None
                else:
                    row["pictureTick"] = eff
                    row["c1_ms"] = ms(tick_time(eff) - r["send"])
                    row["limit_ms"] = frame_ms + row["rtt_ms"]
                    row["pass"] = row["c1_ms"] <= row["limit_ms"] and row["c1_ms"] >= -0.001
                    if row["pass"]:
                        n_pass += 1
                    if eff == r["appliedTick"]:
                        n_pic_matches_receipt += 1
            rows.append(row)
        measured = [r for r in rows if "c1_ms" in r]
        c1_values = [r["c1_ms"] for r in measured]
        report["c1"] = {
            "count": len(c1), "ok200": sum(1 for r in c1 if r["status"] == 200), "measured": len(measured), "missingInPicture": n_missing,
            "appliedFalse": sum(1 for r in c1 if r["status"] == 200 and r.get("applied") is False),
            "pass": n_pass, "max_ms": max(c1_values) if c1_values else None, "mean_ms": (sum(c1_values) / len(c1_values)) if c1_values else None,
            "min_ms": min(c1_values) if c1_values else None, "rtt_p50_ms": percentile([r["rtt_ms"] for r in rows], 0.5),
            "rtt_max_ms": max(r["rtt_ms"] for r in rows) if rows else None,
            "pictureTickEqualsReceipt": n_pic_matches_receipt, "rows": rows,
        }
        c1_ok = frames is not None and len(measured) == len(c1) and n_pass == len(c1)
        hard_fail |= not c1_ok
        lines += ["## C1 命令延迟（发 cut 的 host time → PGM 画面上生效那一拍的拍点时刻）", "",
                  f"- {len(c1)} 次，200 的 {report['c1']['ok200']} 次，画面里找到生效拍的 {len(measured)} 次，缺 {n_missing} 次",
                  f"- 阈值：≤ 1 拍（{frame_ms:.2f} ms）+ 该次 RTT；通过 {n_pass}/{len(c1)}",
                  f"- 数值：min {report['c1']['min_ms']:.2f} / mean {report['c1']['mean_ms']:.2f} / max {report['c1']['max_ms']:.2f} ms；RTT p50 {report['c1']['rtt_p50_ms']:.3f} ms、max {report['c1']['rtt_max_ms']:.3f} ms" if c1_values else "- 没有可算的样本",
                  f"- 回执 appliedTick 与画面生效拍相同：{n_pic_matches_receipt}/{len(measured)}；回执 applied == false 的 {report['c1']['appliedFalse']} 次",
                  f"- 判定：{'✅' if c1_ok else '❌'}", ""]

    # ---- C2 ----
    if snapshots:
        transport = [ms(s["recv"] - s["sentAt"]) for s in snapshots if s.get("sentAt")]
        from_publish = [ms(s["recv"] - s["publishedAt"]) for s in snapshots if s.get("publishedAt")]
        from_tick = [ms(s["recv"] - s["tickTime"]) for s in snapshots if s.get("tickTime")]
        from_tick_clamped = [max(0.0, x) for x in from_tick]
        report["c2"] = {
            "count": len(snapshots),
            "transport_p50_ms": percentile(transport, 0.5), "transport_p99_ms": percentile(transport, 0.99), "transport_max_ms": max(transport) if transport else None,
            "fromPublish_p50_ms": percentile(from_publish, 0.5), "fromPublish_p99_ms": percentile(from_publish, 0.99),
            "fromPublish_max_ms": max(from_publish) if from_publish else None,
            "fromTick_p50_ms": percentile(from_tick, 0.5), "fromTick_p99_ms": percentile(from_tick, 0.99), "fromTick_max_ms": max(from_tick) if from_tick else None,
            "fromTick_min_ms": min(from_tick) if from_tick else None,
            "fromTickClamped_p99_ms": percentile(from_tick_clamped, 0.99),
            "bytes_avg": sum(s["bytes"] for s in snapshots) / len(snapshots),
        }
        c2 = report["c2"]
        c2_ok = (c2["fromTick_p99_ms"] is not None and c2["fromTick_p99_ms"] <= 50 and c2["transport_p99_ms"] <= 50
                 and (c2["fromPublish_p99_ms"] is None or c2["fromPublish_p99_ms"] <= 50))
        hard_fail |= not c2_ok
        lines += ["## C2 状态推送延迟", "",
                  f"- {len(snapshots)} 条快照（平均 {c2['bytes_avg']:.0f} 字节）",
                  f"- 相对拍点（收到时刻 − 该快照生效拍的拍点时刻）：p50 {c2['fromTick_p50_ms']:.2f} / p99 {c2['fromTick_p99_ms']:.2f} / max {c2['fromTick_max_ms']:.2f} ms（min {c2['fromTick_min_ms']:.2f}；负值 = 状态在拍点之前就到了客户端）",
                  f"- 状态机发布 → 客户端收到（收到时刻 − 快照 publishedAt，提案 003）：p50 {c2['fromPublish_p50_ms']:.3f} / p99 {c2['fromPublish_p99_ms']:.3f} / max {c2['fromPublish_max_ms']:.3f} ms" if from_publish else "- 快照没有 publishedAt（旧服务端）",
                  f"- 纯传输（收到时刻 − 服务端序列化时刻）：p50 {c2['transport_p50_ms']:.3f} / p99 {c2['transport_p99_ms']:.3f} / max {c2['transport_max_ms']:.3f} ms",
                  f"- 阈值：p99 ≤ 50 ms（目标 20）；判定：{'✅' if c2_ok else '❌'}", ""]

    # ---- C3 ----
    if frames is not None and snapshots:
        # 每一帧：API 在该拍的 tally（最后一个 tick ≤ 帧拍的快照）里 program == true 的输入集合 必须包含画面里的输入 ID
        idx = 0
        current = None
        strict_mismatch = []
        boundary = []
        undecodable = 0
        compared = 0
        snaps_by_tick = {}
        for s in snapshots:
            snaps_by_tick[s["tick"]] = s
        ticks_sorted = sorted(snaps_by_tick)

        def state_at(tick):
            # 二分：最后一个 tick ≤ tick
            lo, hi = 0, len(ticks_sorted)
            while lo < hi:
                mid = (lo + hi) // 2
                if ticks_sorted[mid] <= tick:
                    lo = mid + 1
                else:
                    hi = mid
            return snaps_by_tick[ticks_sorted[lo - 1]] if lo > 0 else None

        def program_set(s):
            return {int(k) for k, v in s["tally"].items() if v["program"]}

        first_tick = ticks_sorted[0]
        for fobj in frames:
            if fobj["input"] is None:
                undecodable += 1
                continue
            if fobj["tick"] < first_tick:
                continue
            s = state_at(fobj["tick"])
            if s is None:
                continue
            compared += 1
            if fobj["input"] in program_set(s):
                continue
            # 邻拍的状态能解释吗（拍点边界的一帧）
            near = False
            for d in (-1, 1):
                s2 = state_at(fobj["tick"] + d)
                if s2 is not None and fobj["input"] in program_set(s2):
                    near = True
            entry = {"tick": fobj["tick"], "pictureInput": fobj["input"], "apiProgram": sorted(program_set(s)), "apiSnapshotTick": s["tick"]}
            (boundary if near else strict_mismatch).append(entry)
        report["c3"] = {"framesCompared": compared, "undecodable": undecodable, "strictMismatches": len(strict_mismatch),
                        "boundaryMismatches": len(boundary), "strictExamples": strict_mismatch[:20], "boundaryExamples": boundary[:20],
                        "snapshotTickRange": [first_tick, ticks_sorted[-1]]}
        c3_ok = len(strict_mismatch) == 0
        hard_fail |= not c3_ok
        lines += ["## C3 状态一致性（每一帧的输入 ID ∈ API 在该拍 tally.program 为 true 的输入）", "",
                  f"- 比对 {compared} 帧（解不出输入 ID 的 {undecodable} 帧跳过：转场混合帧 / 黑场）",
                  f"- 不一致 {len(strict_mismatch)} 帧；其中能用相邻一拍的状态解释的另计 {len(boundary)} 帧（拍点边界）",
                  f"- 阈值：0 不一致（硬性）；判定：{'✅' if c3_ok else '❌'}"]
        if strict_mismatch:
            lines.append("- 例子：" + "; ".join(f"拍 {e['tick']} 画面 {e['pictureInput']} API {e['apiProgram']}" for e in strict_mismatch[:10]))
        if boundary:
            lines.append("- 边界例子：" + "; ".join(f"拍 {e['tick']} 画面 {e['pictureInput']} API {e['apiProgram']}(快照拍 {e['apiSnapshotTick']})" for e in boundary[:10]))
        lines.append("")

    # ---- C4 ----
    c4 = session.get("c4")
    if c4:
        clients = c4["clients"]
        problems = []
        all_seq = []
        for c in clients:
            seqs = [r["sequence"] for r in c["receipts"]]
            ks = [r["k"] for r in c["receipts"]]
            if len(c["receipts"]) != c["total"]:
                problems.append(f"客户端 {c['client']} 回执 {len(c['receipts'])}/{c['total']}，出错 {len(c['errors'])}")
            if seqs != sorted(seqs):
                problems.append(f"客户端 {c['client']} 回执 sequence 乱序")
            if ks != sorted(ks):
                problems.append(f"客户端 {c['client']} k 乱序")
            if len(set(seqs)) != len(seqs):
                problems.append(f"客户端 {c['client']} sequence 重复")
            final = c4["finalNames"].get(str(c["input"]))
            expect = f"c{c['client']}-{c['total']}"
            if final != expect:
                problems.append(f"客户端 {c['client']} 最终名字 {final!r} ≠ {expect!r}")
            all_seq += seqs
        all_seq.sort()
        holes = 0
        if all_seq:
            holes = (all_seq[-1] - all_seq[0] + 1) - len(set(all_seq))
        if holes:
            problems.append(f"合并后的 sequence 有 {holes} 个空洞")
        # WS 上看到的 sequence 单调不减
        seq_stream = [s["sequence"] for s in sorted(session["snapshots"], key=lambda s: s["recv"])]
        ws_reorder = sum(1 for i in range(1, len(seq_stream)) if seq_stream[i] < seq_stream[i - 1])
        if ws_reorder:
            problems.append(f"WS 快照 sequence 倒退 {ws_reorder} 次")
        rtts = [r["rtt_ticks"] for c in clients for r in c["receipts"]]
        report["c4"] = {"clients": len(clients), "receipts": len(all_seq), "expected": sum(c["total"] for c in clients),
                        "sequenceRange": [all_seq[0], all_seq[-1]] if all_seq else None, "holes": holes, "wsReorders": ws_reorder,
                        "rtt_p50_ms": percentile([ms(x) for x in rtts], 0.5), "rtt_p99_ms": percentile([ms(x) for x in rtts], 0.99),
                        "rtt_max_ms": ms(max(rtts)) if rtts else None,
                        "elapsed": [c["elapsed"] for c in clients], "problems": problems, "finalNames": c4["finalNames"]}
        c4_ok = not problems and all_seq
        hard_fail |= not c4_ok
        lines += ["## C4 并发正确性（每客户端 100 条/s 带序号命令，两个客户端并发）", "",
                  f"- {len(clients)} 个客户端，回执 {len(all_seq)}/{report['c4']['expected']}，sequence {report['c4']['sequenceRange']}，空洞 {holes}，WS 倒退 {ws_reorder}",
                  f"- 每客户端 sequence 与序号 k 同序、最终状态名字 = 最后一条；RTT p50 {report['c4']['rtt_p50_ms']:.3f} / p99 {report['c4']['rtt_p99_ms']:.3f} / max {report['c4']['rtt_max_ms']:.3f} ms" if rtts else "- 没有回执",
                  f"- 阈值：0 丢失 0 乱序（硬性）；判定：{'✅' if c4_ok else '❌'}" + (f"；问题：{'; '.join(problems)}" if problems else ""), ""]

    report["hardFail"] = hard_fail
    text = "\n".join(lines)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text + "\n")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1, ensure_ascii=False)
    print(text)
    return 1 if hard_fail else 0


# ---------- scenario ----------

def cmd_scenario(a):
    ticks_per_s = a.fps
    total = int(round(a.seconds * ticks_per_s))
    events = []
    k = 0
    t = a.cut_every
    while t < a.seconds:
        tick = int(round(t * ticks_per_s))
        k += 1
        next_preview = ((k + 1) % a.inputs) + 1
        if a.fade_every > 0 and abs((t / a.fade_every) - round(t / a.fade_every)) < 1e-9:
            events.append({"tick": tick, "command": {"fade": {"durationTicks": a.fade_ticks}}})
            events.append({"tick": tick + a.fade_ticks + 1, "command": {"setPreview": {"input": next_preview}}})
        else:
            events.append({"tick": tick, "command": {"cut": {}}})
            events.append({"tick": tick + 1, "command": {"setPreview": {"input": next_preview}}})
        t += a.cut_every
    with open(a.out, "w") as f:
        json.dump({"durationTicks": total, "events": events}, f, indent=1)
    print(f"写入 {a.out}：{total} 拍，{len(events)} 个事件（每 {a.cut_every} s 切一次，每 {a.fade_every} s 一次 Fade {a.fade_ticks} 拍）")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--url", default="http://127.0.0.1:8765")
    r.add_argument("--token")
    r.add_argument("--out", required=True)
    r.add_argument("--c1-count", type=int, default=50)
    r.add_argument("--c1-period", type=float, default=1.0)
    r.add_argument("--c1-phase", type=float, default=0.5)
    r.add_argument("--scenario-period", type=float, default=5.0)
    r.add_argument("--c4-seconds", type=float, default=60)
    r.add_argument("--c4-rate", type=float, default=100)
    r.add_argument("--c4-clients", type=int, default=2)
    r.add_argument("--max-seconds", type=float, default=660)
    e = sub.add_parser("evaluate")
    e.add_argument("--session", required=True)
    e.add_argument("--frames")
    e.add_argument("--show")
    e.add_argument("--fps", type=float)
    e.add_argument("--out")
    e.add_argument("--json")
    s = sub.add_parser("scenario")
    s.add_argument("--out", required=True)
    s.add_argument("--seconds", type=float, default=600)
    s.add_argument("--fps", type=float, default=60)
    s.add_argument("--inputs", type=int, default=8)
    s.add_argument("--cut-every", type=float, default=5)
    s.add_argument("--fade-every", type=float, default=60)
    s.add_argument("--fade-ticks", type=int, default=30)
    a = p.parse_args()
    if a.cmd == "run":
        cmd_run(a)
    elif a.cmd == "evaluate":
        sys.exit(cmd_evaluate(a))
    elif a.cmd == "scenario":
        cmd_scenario(a)


if __name__ == "__main__":
    main()
