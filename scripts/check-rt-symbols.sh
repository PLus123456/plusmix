#!/bin/bash
# 实时线程符号检查（make lint 的一部分；W1-D，测试标准 §2.9 / A7）。
#
# 热路径 C target（Packages/SwitcherAudio 的 CSwitcherAudioRT）单独编译，对它每个目标文件 nm -u：
#   1. 禁止清单：malloc / free / 锁 / 条件变量 / os_log / os_signpost / objc_msgSend / swift_* / dispatch_* / 打印 / IO /
#      睡眠 / mach_msg 等，任一出现即失败（设计方案 §3.5：回调里禁止加锁、分配、日志、系统调用、ARC）。
#   2. 允许清单：memcpy / memset 一族、libm 纯函数、栈保护、以及审计过的外部入口
#      （sw_rt_extern.h：libsamplerate src_callback_read / src_reset、libebur128 直方图模式的几个函数、AudioUnitRender、
#      mach_absolute_time、pthread_self）。不在允许清单、也不是本 target 自己定义的符号 → 失败：先审计再加进来。
#   3. 每个热路径 .c 必须 include "sw_rt_pragma.h"（[[clang::nonblocking]] + -Wfunction-effects 升级成错误）。
# 用法：scripts/check-rt-symbols.sh [--release] [--no-build]
set -uo pipefail
cd "$(dirname "$0")/.."

config=debug; build=1
for a in "$@"; do
  case "$a" in
    --release) config=release ;;
    --no-build) build=0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
  esac
done

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
pkg=Packages/SwitcherAudio
target=CSwitcherAudioRT

if [ "$build" = 1 ]; then
  if ! swift build --package-path "$pkg" -c "$config" --target "$target" >/tmp/check-rt-symbols.log 2>&1; then
    red "[check-rt-symbols] 编译 $target 失败："; sed 's/^/    /' /tmp/check-rt-symbols.log | tail -30; exit 1
  fi
fi
objdir=$(ls -d "$pkg"/.build/*/"$config"/"$target".build 2>/dev/null | head -1)
if [ -z "$objdir" ] || ! ls "$objdir"/*.o >/dev/null 2>&1; then
  red "[check-rt-symbols] 找不到 $target 的目标文件（$pkg/.build/*/$config/$target.build/*.o）"; exit 1
fi

# 本 target 自己定义的全局符号
defined=$(nm -g --defined-only "$objdir"/*.o 2>/dev/null | awk '{print $NF}' | sort -u)

deny_re='^_(malloc|calloc|realloc|free|posix_memalign|valloc|aligned_alloc|malloc_zone_[a-z_]*|reallocf)$|^_pthread_(mutex|cond|rwlock|join|create|once|kill|exit|setname)|^_os_unfair_lock|^_os_log|^_os_signpost|^_objc_|^_swift_|^_dispatch_|^_(printf|fprintf|vfprintf|snprintf|puts|putchar|fputs|fwrite|NSLog|write|read|open|close|usleep|nanosleep|sleep|exit|abort|__assert_rtn|fopen|fclose|syscall|select|poll|kevent|ioctl)$|^_mach_msg|^_(sem_|semaphore_)|^_CF|^_NS'
allow_re='^_(memcpy|memset|memmove|bzero|__memcpy_chk|__memset_chk|__memmove_chk|__stack_chk_fail|__stack_chk_guard)$|^_(sinf|cosf|tanf|sin|cos|tan|exp|expf|exp2|exp2f|log|logf|log10|log10f|log2|log2f|pow|powf|sqrt|sqrtf|fabs|fabsf|floor|floorf|ceil|ceilf|lrint|lrintf|round|roundf|fmod|fmodf|fmin|fminf|fmax|fmaxf|sincos|sincosf|__sincos_stret|__sincosf_stret)$|^_(AudioUnitRender|src_callback_read|src_reset|ebur128_add_frames_float|ebur128_loudness_momentary|ebur128_loudness_shortterm|ebur128_loudness_global|ebur128_loudness_range|ebur128_prev_sample_peak|ebur128_prev_true_peak|mach_absolute_time|pthread_self|sw_audio_ring_layout_version)$'

status=0
for o in "$objdir"/*.o; do
  # 只看有对应源文件的目标文件（删掉的源文件留下的 .o 不算）
  src="$pkg/Sources/$target/$(basename "$o" .o)"
  [ -f "$src" ] || continue
  undef=$(nm -u "$o" 2>/dev/null | awk '{print $NF}' | sort -u)
  bad=""; unknown=""
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    if printf '%s' "$s" | grep -Eq "$deny_re"; then bad+="$s "; continue; fi
    if printf '%s' "$s" | grep -Eq "$allow_re"; then continue; fi
    if printf '%s\n' "$defined" | grep -qx -- "$s"; then continue; fi
    unknown+="$s "
  done <<< "$undef"
  if [ -n "$bad" ]; then red "[check-rt-symbols] $(basename "$o")：禁止的符号：$bad"; status=1; fi
  if [ -n "$unknown" ]; then red "[check-rt-symbols] $(basename "$o")：未审计的外部符号（审计后加进允许清单）：$unknown"; status=1; fi
done

# 每个热路径源文件都要带 nonblocking 的编译期检查
for c in "$pkg"/Sources/"$target"/*.c; do
  grep -q '#include "sw_rt_pragma.h"' "$c" || { red "[check-rt-symbols] $(basename "$c") 没有 include sw_rt_pragma.h（-Wfunction-effects 未升级成错误）"; status=1; }
done

if [ "$status" = 0 ]; then
  n=$(ls "$pkg"/Sources/"$target"/*.c | wc -l | tr -d ' ')
  green "[check-rt-symbols] $target（$config）$n 个目标文件：无 malloc / 锁 / 日志 / ObjC / Swift 运行时 / 系统调用符号；外部符号都在审计清单内"
fi
exit $status
