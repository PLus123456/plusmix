#!/bin/bash
# 网络损伤（测试标准 §2.6）：用 macOS 自带的 dummynet（dnctl）+ pf（pfctl）对指定端口做断网 / 限速 / 丢包 / 延迟。
# 需要 sudo。规则放在 pf 锚点 com.apple/switcher-netem 里（/etc/pf.conf 的 "com.apple/*" 通配锚点会自动带上它，不改系统文件）。
#
# 用法（都要 sudo）：
#   scripts/netem.sh block  PORT [SECONDS]            封端口（TCP + UDP，两个方向）；给了秒数就到时自动放开
#   scripts/netem.sh limit  PORT KBIT [SECONDS]       上行限速到 KBIT kbit/s（发往 PORT 的包走 dummynet 管道）
#   scripts/netem.sh loss   PORT PERCENT [SECONDS]    发往 PORT 的包按百分比丢
#   scripts/netem.sh delay  PORT MS [SECONDS]         发往 PORT 的包加固定延迟
#   scripts/netem.sh shape  PORT KBIT PERCENT MS [SECONDS]   限速 + 丢包 + 延迟一起
#   scripts/netem.sh clear                            清掉本脚本加的所有规则和管道
#   scripts/netem.sh status                           看当前规则
#   scripts/netem.sh serve [DIR]                      代理模式：循环读 DIR/netem.request（默认 /tmp/switcher-netem），
#                                                     每行一条上面的子命令（不含 sudo），执行后把结果写到 DIR/netem.reply。
#                                                     StreamingTests 在 SWITCHER_NETEM=broker 时用它，这样测试进程不需要 sudo，
#                                                     也不受 sudo 5 分钟凭证过期影响（E9 一跑 5 分钟）。Ctrl-C 退出时自动 clear。
#
# E7 / E8：先起三个 MediaMTX 实例（见 scripts/mediamtx.yml 头部），推三路到 1935 / 1936 / 1937，然后
#   sudo scripts/netem.sh block 1936 30        → 第 2 路断 30 s；第 1、3 路丢帧应为 0，第 2 路 30 s 后自动重连。
# E9：sudo scripts/netem.sh limit 1935 4200 300  → 6 Mbps 的流限到 70%，跑 5 分钟。
#
# 没有 sudo 时：StreamingTests 默认用进程内的用户态代理（ThrottleProxy，限速 / 黑洞）跑同样的 E7 / E8 / E9；设 SWITCHER_NETEM 才走这里。
#
# SRT 提醒：MediaMTX 的 srtAddress 必须显式绑 IPv4（scripts/mediamtx.yml 里是 0.0.0.0:8890）；":8890" 双栈 UDP 收不到 IPv4 回环的握手。
# 从别的机器推 SRT 进来还要在应用防火墙里放行 mediamtx（ad-hoc 签名，系统不会自动放行）：
#   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add "$(realpath /opt/homebrew/bin/mediamtx)"
#   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --unblockapp "$(realpath /opt/homebrew/bin/mediamtx)"
#
# 注意：
# - 本机回环（lo0）上 pf 也生效；限速只对"发往 PORT"的方向（上行），服务器回来的 ACK 不限。
# - 管道编号固定 1（限速 / 丢包 / 延迟共用一条管道），多个端口同时限速请分次用不同脚本实例——一期只需要单端口。
# - pfctl -E 会启用 pf 并拿到一个引用令牌；clear 用令牌释放（pfctl -X），不影响系统其他 pf 用户。
set -u

ANCHOR="com.apple/switcher-netem"
STATE_DIR="${SWITCHER_NETEM_STATE:-/var/tmp/switcher-netem}"
TOKEN_FILE="$STATE_DIR/pf-token"
PIPE=1

die() { echo "netem: $*" >&2; exit 2; }
need_root() { [ "$(id -u)" = "0" ] || die "需要 sudo：sudo $0 $*"; }

pf_enable() {
    mkdir -p "$STATE_DIR"
    if [ ! -s "$TOKEN_FILE" ]; then
        # pfctl -E 输出 "Token : 12345" 到 stderr
        local out
        out=$(pfctl -E 2>&1) || true
        echo "$out" | sed -n 's/.*Token *: *\([0-9]*\).*/\1/p' | head -1 > "$TOKEN_FILE"
    fi
}

pf_release() {
    if [ -s "$TOKEN_FILE" ]; then
        pfctl -X "$(cat "$TOKEN_FILE")" >/dev/null 2>&1 || true
        rm -f "$TOKEN_FILE"
    fi
}

load_rules() {
    # 从 stdin 读规则装进锚点
    pfctl -q -a "$ANCHOR" -f - 
}

do_clear() {
    pfctl -q -a "$ANCHOR" -F all 2>/dev/null || true
    dnctl -q pipe delete $PIPE 2>/dev/null || true
    pf_release
    echo "netem: 已清空"
}

do_block() {
    local port="$1"
    pf_enable
    load_rules <<RULES
block drop quick proto tcp from any to any port $port
block drop quick proto tcp from any port $port to any
block drop quick proto udp from any to any port $port
block drop quick proto udp from any port $port to any
RULES
    echo "netem: 端口 $port 已封（TCP+UDP）"
}

# 参数：port kbit plr_percent delay_ms（0 = 不设）
do_shape() {
    local port="$1" kbit="$2" plr="$3" delay="$4"
    pf_enable
    local cfg="dnctl pipe $PIPE config"
    [ "$kbit" != "0" ] && cfg="$cfg bw ${kbit}Kbit/s"
    [ "$plr" != "0" ] && cfg="$cfg plr $(awk "BEGIN{printf \"%.4f\", $plr/100}")"
    [ "$delay" != "0" ] && cfg="$cfg delay ${delay}ms"
    $cfg || die "dnctl 失败"
    load_rules <<RULES
dummynet out quick proto tcp from any to any port $port pipe $PIPE
dummynet out quick proto udp from any to any port $port pipe $PIPE
RULES
    echo "netem: 发往端口 ${port} 的包 → 管道 ${PIPE}（bw ${kbit}kbit/s, plr ${plr}%, delay ${delay}ms）"
}

do_status() {
    echo "== pf 锚点 $ANCHOR =="
    pfctl -a "$ANCHOR" -sr 2>/dev/null || echo "(无)"
    echo "== dummynet 管道 =="
    dnctl list 2>/dev/null || echo "(无)"
}

# 有秒数就到时自动清
auto_clear_after() {
    local secs="${1:-}"
    if [ -n "$secs" ]; then
        echo "netem: $secs 秒后自动清除"
        sleep "$secs"
        do_clear
    fi
}

run_command() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        block)  [ $# -ge 1 ] || die "block PORT [SECONDS]"; do_block "$1"; auto_clear_after "${2:-}" ;;
        limit)  [ $# -ge 2 ] || die "limit PORT KBIT [SECONDS]"; do_shape "$1" "$2" 0 0; auto_clear_after "${3:-}" ;;
        loss)   [ $# -ge 2 ] || die "loss PORT PERCENT [SECONDS]"; do_shape "$1" 0 "$2" 0; auto_clear_after "${3:-}" ;;
        delay)  [ $# -ge 2 ] || die "delay PORT MS [SECONDS]"; do_shape "$1" 0 0 "$2"; auto_clear_after "${3:-}" ;;
        shape)  [ $# -ge 4 ] || die "shape PORT KBIT PERCENT MS [SECONDS]"; do_shape "$1" "$2" "$3" "$4"; auto_clear_after "${5:-}" ;;
        clear)  do_clear ;;
        status) do_status ;;
        *) sed -n '2,20p' "$0"; exit 2 ;;
    esac
}

do_serve() {
    local dir="${1:-/tmp/switcher-netem}"
    mkdir -p "$dir"
    chmod 777 "$dir"
    local req="$dir/netem.request" rep="$dir/netem.reply" lock="$dir/.serve.lock"
    # 只允许一个代理：两个 serve 同时读同一个请求文件会各读一半、各回一份、pfctl 撞锁（DIOCADDRULE: Resource busy）——
    # G3 的 E8 就是这么挂的（下午 15:06 起的一个代理没关，晚上又起了一个）。锁目录里记 pid，活着就拒绝，死了就接管。
    if ! mkdir "$lock" 2>/dev/null; then
        local other
        other=$(cat "$lock/pid" 2>/dev/null || echo "")
        if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
            echo "netem: 已经有一个代理在跑（pid ${other}，$(ps -o lstart= -p "$other" 2>/dev/null | sed 's/^ *//')，tty $(ps -o tty= -p "$other" 2>/dev/null)）。" >&2
            echo "netem: 先在它的终端 Ctrl-C，或者 sudo kill ${other}；再起本代理。" >&2
            exit 2
        fi
        echo "netem: 上一个代理（pid ${other:-?}）已不在，接管锁"
    fi
    echo $$ > "$lock/pid"
    rm -f "$req" "$rep" "$rep".tmp.*
    echo "netem: 代理模式，监听 ${req}（pid $$；Ctrl-C 退出；退出前会 clear）"
    trap 'do_clear; rm -rf "$lock" "$rep".tmp.*; exit 0' INT TERM
    local n=0
    while true; do
        if [ -s "$req" ]; then
            # 原子认领：把请求文件改名拿走再读，读的是完整文件（不是 head -1 后再截断的窗口），空行跳过
            local claimed="$req.$$.$n"
            if mv -f "$req" "$claimed" 2>/dev/null; then
                local line
                line=$(grep -v '^[[:space:]]*$' "$claimed" | head -1)
                rm -f "$claimed"
                if [ -z "$line" ]; then
                    echo "netem: 收到空请求，忽略"
                else
                    echo "netem: 收到：$line"
                    # 每个请求自己的临时回复文件（带秒数的命令在后台继续跑并往里写，不和下一个请求共用）；reply 立刻写
                    local tmp="$rep.tmp.$n"
                    rm -f "$rep.tmp.$((n - 1))"   # 上一个请求的临时文件（它的后台进程若还在写，写进的是已删除的 inode，无害）
                    # shellcheck disable=SC2086
                    ( run_command $line ) > "$tmp" 2>&1 &
                    sleep 0.3
                    cat "$tmp" 2>/dev/null
                    cp -f "$tmp" "$rep.new" 2>/dev/null && mv -f "$rep.new" "$rep" 2>/dev/null || true
                fi
                n=$((n + 1))
            fi
        fi
        sleep 0.2
    done
}

case "${1:-}" in
    serve) need_root; do_serve "${2:-}" ;;
    status) do_status ;;
    ""|-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) need_root "$@"; run_command "$@" ;;
esac
