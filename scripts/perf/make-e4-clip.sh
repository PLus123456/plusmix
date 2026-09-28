#!/bin/bash
# E4 的固定测试片段（测试标准 §3 E4："自有素材，含静态、慢动、高动态三段"）：全部由 ffmpeg 的 lavfi 信号源现场合成，
# 没有任何外来素材（版权干净、每台机器都能生成）。同一版 ffmpeg 生成的文件逐字节相同，sha256 进基线；换了 ffmpeg 片段变了，E4 就不与上一版判退步。
#
#   底图：一帧曼德博分形（3840×1080）+ 固定图样的细颗粒（noise 不带 t = 每帧同一图样）
#   0–10 s   静态：底图中间 1920 宽静止不动
#   10–20 s  慢动：在底图上每秒平移 30 px（半像素 / 帧）
#   20–30 s  高动态：正弦摆动快速平移（峰值约 35 px / 帧）+ 每帧变化的噪声（allf=t）+ 亮度 1.3 Hz 起伏 + 色相旋转
#            （亮度起伏也是 perf-baseline 对齐录像与源的依据：逐帧亮度均值序列做滑动比对）
#   视频：ProRes 422 HQ 10-bit，1920×1080@60，BT.709 限制范围（文件输入走 VideoToolbox 硬解）；音频：48 kHz 立体声 440 Hz −20 dBFS（PCM）
#
# 用法：scripts/perf/make-e4-clip.sh [--out .build/perf/e4] [--segment-seconds 10] [--force]
# 输出：<out>/e4-source.mov、<out>/e4-source.json（sha256、ffmpeg 版本、各段帧区间）。已存在且 --force 没给就不重做。
set -uo pipefail
cd "$(dirname "$0")/../.."
export PATH="/opt/homebrew/bin:$PATH"

out=.build/perf/e4; seg=10; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --segment-seconds) seg="$2"; shift 2 ;;
    --force) force=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "不认识的参数：$1" >&2; exit 2 ;;
  esac
done
command -v ffmpeg >/dev/null || { echo "没有 ffmpeg（brew install ffmpeg）" >&2; exit 2; }
mkdir -p "$out"
clip="$out/e4-source.mov"; meta="$out/e4-source.json"
if [ "$force" = 0 ] && [ -s "$clip" ] && [ -s "$meta" ]; then
  echo "E4 片段已存在：${clip}（sha256 $(python3 -c "import json;print(json.load(open('$meta'))['sha256'][:12])")）"
  exit 0
fi

fps=60; frames=$((seg * fps)); total=$((3 * seg))
tmp="$clip.part.mov"
# 底图只渲染一帧（trim），再 loop 成无限长，三路 split 各取 frames 帧；crop 的 t 在各段 setpts 归零之后从 0 数
graph="mandelbrot=size=3840x1080:rate=${fps},trim=end_frame=1,loop=loop=-1:size=1:start=0,setpts=N/${fps}/TB,format=yuv444p,split=3[b1][b2][b3];
[b1]trim=end_frame=${frames},setpts=PTS-STARTPTS,crop=1920:1080:960:0,noise=alls=10:allf=u:all_seed=1234[s];
[b2]trim=end_frame=${frames},setpts=PTS-STARTPTS,crop=1920:1080:x='trunc(t*30)':y=0,noise=alls=10:allf=u:all_seed=1234[m];
[b3]trim=end_frame=${frames},setpts=PTS-STARTPTS,crop=1920:1080:x='trunc(960+960*sin(2*PI*t*0.35))':y=0,noise=alls=18:allf=t+u:all_seed=4321,eq=brightness='0.06*sin(2*PI*t*1.3)':eval=frame,hue=h='t*36'[h];
[s][m][h]concat=n=3:v=1:a=0,scale=out_color_matrix=bt709:out_range=tv,format=yuv422p10le,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv[v];
sine=frequency=440:sample_rate=48000:duration=${total},volume=0.1,aformat=channel_layouts=stereo[a]"
echo "== 生成 E4 片段（${total} s = 静态 / 慢动 / 高动态各 ${seg} s）→ $clip"
if ! ffmpeg -hide_banner -loglevel error -y -filter_complex "$graph" -map '[v]' -map '[a]' \
      -c:v prores_ks -profile:v 3 -vendor apl0 -pix_fmt yuv422p10le -r "$fps" \
      -color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv \
      -c:a pcm_s16le -ar 48000 -t "$total" -movflags +faststart "$tmp"; then
  rm -f "$tmp"; echo "ffmpeg 生成失败" >&2; exit 1
fi
mv "$tmp" "$clip"
sha=$(shasum -a 256 "$clip" | cut -d' ' -f1)
nb=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$clip" 2>/dev/null)
python3 - "$meta" "$sha" "$(ffmpeg -version | head -1)" "$seg" "$fps" "$nb" <<'PY'
import json, sys
meta, sha, ver, seg, fps, nb = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
n = seg * fps
json.dump({"sha256": sha, "ffmpeg": ver, "fps": fps, "frames": int(nb or 0), "width": 1920, "height": 1080,
           "segments": [["static", 0, n], ["slow", n, 2 * n], ["high", 2 * n, 3 * n]],
           "codec": "prores_ks profile 3 (422 HQ) yuv422p10le bt709 tv; pcm_s16le 48k stereo 440 Hz -20 dBFS"},
          open(meta, "w"), ensure_ascii=False, indent=1)
PY
echo "   $(du -h "$clip" | cut -f1)，$nb 帧，sha256 ${sha:0:12}"
