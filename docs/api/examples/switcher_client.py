#!/usr/bin/env python3
"""Switcher 本地 API 的最小客户端（只用 Python 3 标准库）。

    python3 docs/api/examples/switcher_client.py state                 # PGM / PVW / tally 一览
    python3 docs/api/examples/switcher_client.py cut                   # 发一条命令
    python3 docs/api/examples/switcher_client.py preview 3             # PVW 选 3 号
    python3 docs/api/examples/switcher_client.py cmd '{"fade":{"durationTicks":30}}'   # 任意命令 JSON
    python3 docs/api/examples/switcher_client.py watch                 # 订阅 WebSocket，打印每次 tally 变化与推送延迟
                                                                      #（收到时刻 − 快照生效拍点；命令在下一拍生效，快照常常早于拍点到达，所以负几毫秒是正常的）

环境变量：SWITCHER_URL（默认 http://127.0.0.1:8765）、SWITCHER_TOKEN（设了鉴权时）。
WebSocket 部分自己实现 RFC 6455 的文本帧（客户端要掩码、服务端不掩码），够订阅事件用；正式项目请换 websockets / websocket-client 之类的库。
"""
import base64
import ctypes
import json
import os
import socket
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("SWITCHER_URL", "http://127.0.0.1:8765").rstrip("/")
TOKEN = os.environ.get("SWITCHER_TOKEN")


def headers():
    h = {"Content-Type": "application/json"}
    if TOKEN:
        h["Authorization"] = f"Bearer {TOKEN}"
    return h


def get(path):
    req = urllib.request.Request(BASE + path, headers=headers())
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)


def post_command(command):
    """POST /api/v1/command；400 时把服务端的理由打出来再抛。"""
    body = json.dumps({"command": command}).encode()
    req = urllib.request.Request(BASE + "/api/v1/command", data=body, headers=headers(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{e.code}: {e.read().decode()}")


def host_time_now():
    """mach_absolute_time()，与服务端时间戳同一个钟（只在同一台 Mac 上有意义）。"""
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    libc.mach_absolute_time.restype = ctypes.c_uint64
    return libc.mach_absolute_time()


# ---------- WebSocket（最小实现） ----------

class WebSocket:
    def __init__(self, url):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        path = u.path + (f"?{u.query}" if u.query else "")
        req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n")
        if TOKEN:
            req += f"Authorization: Bearer {TOKEN}\r\n"
        self.sock.sendall((req + "\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("握手时连接被关")
            response += chunk
        status = response.split(b"\r\n", 1)[0].decode()
        if " 101 " not in status:
            raise ConnectionError(f"握手失败：{status}")
        self.buffer = response.split(b"\r\n\r\n", 1)[1]

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("连接被关")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def send_text(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def recv_text(self):
        """返回下一条文本帧（自动回 pong，跳过其他控制帧）。"""
        while True:
            b0, b1 = self._read(2)
            opcode, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            payload = self._read(n)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x1:
                return payload.decode()
            if opcode == 0x9:                       # ping → pong
                self.sock.sendall(bytes([0x8A, 0x80]) + b"\x00\x00\x00\x00")
            elif opcode == 0x8:
                raise ConnectionError("服务端关闭了连接")


# ---------- 子命令 ----------

def cmd_state():
    s = get("/api/v1/state")
    st = s["state"]
    names = {i["number"]: i["name"] for i in st["inputs"]}
    print(f"版本 {s['version']}  序号 {s['sequence']}  拍 {s['tick']}  PGM {st['program']} ({names.get(st['program'], '黑场')})  PVW {st['preview']} ({names.get(st['preview'], '黑场')})")
    for n, t in sorted(s["tally"].items(), key=lambda kv: int(kv[0])):
        flag = "PGM" if t["program"] else ("PVW" if t["preview"] else "   ")
        print(f"  {flag} {n:>2} {names.get(int(n), '')}")
    stats = s.get("stats")
    if stats:
        print(f"统计：render {stats['render_ms']:.2f} ms  missed {stats['missed_render']}  jitter {stats['jitter_ms']:.2f} ms  cpu {stats['cpu_pct']:.0f}%  gpu {stats['gpu_pct']:.0f}%")


def cmd_watch():
    ws_url = BASE.replace("http://", "ws://").replace("https://", "wss://") + "/api/v1/events"
    ws = WebSocket(ws_url)
    timebase = None
    last_tally = None
    print(f"已连接 {ws_url}，Ctrl-C 退出", flush=True)
    while True:
        msg = json.loads(ws.recv_text())
        kind = msg["type"]
        if kind == "hello":
            timebase = msg["timebase"]
            print(f"hello：版本 {msg['version']}", flush=True)
        elif kind == "snapshot":
            tally = {n: ("PGM" if t["program"] else "PVW" if t["preview"] else "-") for n, t in msg["tally"].items()}
            if tally != last_tally:
                latency = ""
                if timebase and msg.get("tickTime"):
                    ns = (host_time_now() - msg["tickTime"]) * timebase["numer"] / timebase["denom"]
                    latency = f"  推送延迟（收到 − 拍点）{ns / 1e6:.1f} ms"
                print(f"seq {msg['sequence']} tick {msg['tick']}  PGM {msg['state']['program']}  PVW {msg['state']['preview']}  tally {tally}{latency}", flush=True)
                last_tally = tally
        elif kind == "stats":
            s = msg["stats"]
            print(f"stats：render {s['render_ms']:.2f} ms  missed {s['missed_render']}  encoder {[(e['output'], e['state']) for e in s['encoder']]}", flush=True)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    verb = argv[1]
    if verb == "state":
        cmd_state()
    elif verb == "watch":
        cmd_watch()
    elif verb == "cut":
        print(post_command({"cut": {}}))
    elif verb == "preview":
        print(post_command({"setPreview": {"input": int(argv[2])}}))
    elif verb == "program":
        print(post_command({"setProgram": {"input": int(argv[2])}}))
    elif verb == "cmd":
        print(post_command(json.loads(argv[2])))
    else:
        print(f"不认识的子命令：{verb}\n{__doc__}")
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        pass
