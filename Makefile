# Switcher 仓库入口。目标：gen / build / test / lint / clean（CLAUDE.md 有说明）。
# Claude 的 Bash 是非登录 shell，拿不到 brew 的 PATH，所以这里自己补上（传给子进程和脚本）。
# 注意 macOS 自带的 make 3.81 定位命令时用的是它自己启动时的 PATH，所以 brew 工具要写全路径。
SHELL := /bin/bash
BREW_PREFIX ?= /opt/homebrew
export PATH := $(BREW_PREFIX)/bin:$(PATH)
XCODEGEN ?= $(BREW_PREFIX)/bin/xcodegen
# XcodeGen 会把 ${DEVELOPMENT_TEAM} 原样写进工程（未设置时不会替换成空），所以保证它至少是空串。
export DEVELOPMENT_TEAM ?=

PACKAGES := Packages/SwitcherCore Packages/SwitcherInputs Packages/SwitcherAudio \
            Packages/SwitcherOutputs Packages/SwitcherControl Packages/SwitcherTestKit
TOOLS    := Tools/switcher-headless Tools/frameprobe

XCODEPROJ   := Switcher.xcodeproj
SCHEME      := Switcher
DERIVED     := .build/DerivedData
DESTINATION := platform=macOS,arch=arm64
XCB         := xcodebuild -project $(XCODEPROJ) -scheme $(SCHEME) -destination '$(DESTINATION)' -derivedDataPath $(DERIVED)
XCB_FLAGS   ?= -quiet
# G13（2026-11-07）：本机开发签名——钥匙串里有 Apple Development 身份时 `make build-app DEV_SIGN_TEAM=<Team ID>`（test-app 同），
# scripts/dev-signing/dev-signing.xcconfig 以 -xcconfig 盖过工程的 ad-hoc 设置：稳定的 Team ID + bundle id，TCC 授权跨重编译不重问。
# 不设就是原来的 ad-hoc（每次编译 CDHash 变、系统当新 App 重问权限）。Personal Team 也能签；只管本机跑，发布仍走 make archive（W4-B）。
DEV_SIGN_TEAM ?=
ifneq ($(DEV_SIGN_TEAM),)
XCB += -xcconfig scripts/dev-signing/dev-signing.xcconfig DEV_SIGN_TEAM=$(DEV_SIGN_TEAM)
endif

# make lint 检查的分支：默认当前分支；检查别的分支用 make lint BRANCH=w1-core
BRANCH ?= $(shell git symbolic-ref --short -q HEAD 2>/dev/null || echo main)
# 会话新增的检查脚本：放 scripts/ 下、名字以 check- 或 lint- 开头就会自动挂进来（docs/OWNERSHIP.md 补充规则 4）
EXTRA_LINTS := $(filter-out scripts/lint-rules.sh scripts/check-deps.sh scripts/check-ownership.sh,\
                 $(wildcard scripts/lint-*.sh scripts/check-*.sh))

.PHONY: all gen build test lint clean help manual build-packages build-tools build-app test-packages test-tools test-app frameprobe-release

all: gen build test lint

help:
	@echo "make gen    生成 $(XCODEPROJ)（XcodeGen；DEVELOPMENT_TEAM 环境变量可选）"
	@echo "make build  编译所有包、两个工具、App"
	@echo "make test   所有包 swift test + 两个工具跑一次冒烟 + App 的 xcodebuild test"
	@echo "make lint   scripts/lint-rules.sh + check-deps.sh + check-ownership.sh \$$BRANCH + scripts/{check,lint}-*.sh"
	@echo "make clean  删掉所有 .build 和生成的工程"
	@echo "make manual 随包 HTML 手册：docs/user（中英）→ App/Resources/Help/（docs/tools/build-help.py；改了 docs/user 要重跑，make lint 的 scripts/check-help.sh 会查）"
	@echo "make archive  发布归档：签名 → 校验 → DMG → 公证（W4-B，scripts/release/release.mk；archive-adhoc / release-test / appcast / pin-check 也在那里）"
	@echo "make build-app DEV_SIGN_TEAM=<Team ID>  本机开发签名（钥匙串里的 Apple Development 身份；TCC 授权跨重编译不重问）；test-app 同"

# ---------- gen ----------
gen:
	$(XCODEGEN) generate --quiet
	@# 新 worktree 第一次解析会把 swift-collections 解到 1.7.0（要 Swift 6.4 运行时，macOS 26.6.2 的 libswiftCore 没有 _swift_initBorrow，App 一起就崩，
	@# reports/issues/W3C2-g5-swift-collections-1.7-dyld-crash.md）。工作区的 Package.resolved 是生成物，这里从入库的模板拷一份钉住（与各包入库的 Package.resolved 同一套版本）；
	@# 升依赖是 W4-B 的事：改模板 + 各包的 Package.resolved 一起改，并在 macOS 15 / 26 各起一次 App 与 frameprobe。SWITCHER_KEEP_RESOLVED=1 跳过拷贝。
	@if [ -z "$$SWITCHER_KEEP_RESOLVED" ] && [ -f scripts/xcode-workspace-Package.resolved ]; then \
	  mkdir -p $(XCODEPROJ)/project.xcworkspace/xcshareddata/swiftpm && \
	  cp scripts/xcode-workspace-Package.resolved $(XCODEPROJ)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; fi

$(XCODEPROJ)/project.pbxproj: project.yml
	$(MAKE) gen

# ---------- build ----------
build: build-packages build-tools build-app

build-packages:
	@for p in $(PACKAGES); do echo "== swift build $$p"; swift build --package-path $$p || exit 1; done

build-tools:
	@for t in $(TOOLS); do echo "== swift build $$t"; swift build --package-path $$t || exit 1; done

build-app: $(XCODEPROJ)/project.pbxproj
	@echo "== xcodebuild build $(SCHEME)"
	$(XCB) $(XCB_FLAGS) build

# ---------- test ----------
# 三组都跑完再判（P4 / W3-E3 / W3-C3 三个会话都撞到"第一个包红了后面全不跑"：macOS 27 上 SwitcherRender 有 3 处环境红，make test 每次都停在第一个包）
test:
	@fail=0; for t in test-tools test-packages test-app; do $(MAKE) --no-print-directory $$t || fail=1; done; \
	  [ $$fail = 0 ] || { echo "make test：有失败的组（见上）"; exit 1; }

# T04（Codex 2026-10-13 审查，G9 修）：包测试里 MediaMTX / ISO 用例与 App 的推流 / ISO 用例直接调 Tools/frameprobe/.build/release/frameprobe，
# 旧二进制也算"有"——test 原来先跑包测试、后编工具，用例拿到的是上一次编的 frameprobe（9 月的旧 CLI 对新参数只回版本号、9 条推流用例"没有 JSON"）。
# 现在包测试 / App 测试前先把 release 版编到当前源码；make test 的三组改成 test-tools 在前。
frameprobe-release:
	@echo "== swift build -c release Tools/frameprobe"; swift build -c release --package-path Tools/frameprobe

test-packages: frameprobe-release
	@failed=""; for p in $(PACKAGES); do echo "== swift test $$p"; swift test --package-path $$p || failed="$$failed $$p"; done; \
	  if [ -n "$$failed" ]; then echo "test-packages：失败的包：$$failed"; exit 1; else echo "test-packages：$(words $(PACKAGES)) 个包全过"; fi

# 工具目前只打印版本；冒烟 = 编出来、跑得起、输出里有自己的名字和版本号
test-tools:
	@for t in $(TOOLS); do \
	  name=$$(basename $$t); echo "== smoke $$name"; \
	  swift build --package-path $$t || exit 1; \
	  bin="$$(swift build --package-path $$t --show-bin-path)/$$name"; \
	  out="$$($$bin)"; echo "   $$out"; \
	  echo "$$out" | grep -qE "^$$name [0-9]+\.[0-9]+\.[0-9]+" || { echo "   冒烟失败：$$bin 输出不含版本"; exit 1; }; \
	done

test-app: frameprobe-release $(XCODEPROJ)/project.pbxproj
	@echo "== xcodebuild test $(SCHEME)"
	$(XCB) $(XCB_FLAGS) test

# ---------- 随包 HTML 手册（W4-C2 / prompt 103 给的一行，G8b 挂上；Makefile 里 help 已被用法占用，所以叫 manual）----------
# docs/user（中英）→ App/Resources/Help/（产物入库，project.yml 的 Help folder reference 把整个目录带进包）；输出确定、文档没变重跑无 diff。
# 改了 docs/user 忘了重跑：make lint 自动带上的 scripts/check-help.sh（build-help.py --check）会红。
manual:
	python3 docs/tools/build-help.py

# ---------- lint ----------
lint:
	scripts/lint-rules.sh
	scripts/check-deps.sh
	scripts/check-ownership.sh $(BRANCH)
	@for s in $(EXTRA_LINTS); do echo "== $$s"; $$s || exit 1; done

# ---------- clean ----------
clean:
	rm -rf .build $(XCODEPROJ)
	@for p in $(PACKAGES) $(TOOLS); do rm -rf $$p/.build; done

# ---------- G2 检查点（M0 核心循环）----------
# make gate2     跑 10 分钟标准负载 → frameprobe → StatsSummary → reports/G2-run-10min.md + reports/G2.md，并写 baselines/m0-m5max.json
# make gate2-1h  60 分钟版（用户触发），与 10 分钟基线比，结果并入 reports/G2.md
# 数据留在 .build/gate2/<label>/（不入库）。脚本：scripts/gate2.sh、scripts/gate2-report.py
GATE2_BASELINE ?= baselines/m0-m5max.json
.PHONY: gate2 gate2-1h
gate2:
	scripts/gate2.sh --minutes 10 --label 10min --write-baseline $(GATE2_BASELINE)

gate2-1h:
	scripts/gate2.sh --minutes 60 --label 1h --baseline $(GATE2_BASELINE)

# ---------- G3 检查点（M1 切换 + M2 音频 + M3 输出 + M5 控制）----------
# make gate3      L0 + L1（六个包 swift test + 两个工具冒烟）→ 10 分钟 G3 场景（scripts/gate3.sh：V1–V7、A1–A4、E1–E3、C1–C4）
#                 → reports/G3-run-10min.md + reports/G3.md，并写 baselines/g3-m5max.json
# make gate3-run  只跑 10 分钟场景（跳过 L0 / L1）；make gate3-1h 60 分钟版（用户触发）
# make gate3-net  E7–E9：需要用户先在另一个终端 sudo scripts/netem.sh serve（scripts/gate3-net.sh 会检查代理只有一个且在线），跑完自动重拼 reports/G3.md
# 数据留在 .build/gate3/<label>/（不入库）。
GATE3_BASELINE ?= baselines/g3-m5max.json
.PHONY: gate3 gate3-run gate3-1h gate3-net
gate3: test-packages test-tools
	scripts/gate3.sh --minutes 10 --label 10min --write-baseline $(GATE3_BASELINE)

gate3-run:
	scripts/gate3.sh --minutes 10 --label 10min --write-baseline $(GATE3_BASELINE)

gate3-1h:
	scripts/gate3.sh --minutes 60 --label 1h --baseline $(GATE3_BASELINE)

gate3-net:
	@echo "E7–E9 需要网络损伤（dummynet + pf）。先在另一个终端跑（要 sudo，Ctrl-C 退出时自动清规则）："
	@echo "    sudo scripts/netem.sh serve"
	scripts/gate3-net.sh
	$(MAKE) gate3-report

# make gate3-report  只用已有的 .build/gate3/10min 产物重出 reports/G3-run-10min.md 并拼 reports/G3.md（改了 G3-notes.md 或跑完 gate3-net 之后用；不跑、不解码）
.PHONY: gate3-report
gate3-report:
	python3 scripts/gate3-report.py --out-dir .build/gate3/10min --label 10min --minutes 10 --show scenarios/g3-show.json --script scenarios/g3.json \
	  --baseline "" --run-report reports/G3-run-10min.md --notes reports/G3-notes.md --report reports/G3.md


# ---------- G4 检查点（M4 输入 + M6 叠加与其它输出）----------
# make gate4        L0 + L1（六个包 swift test，含 W3-B 扩展后的 V8 参考图集 + 两个工具冒烟）→ 10 分钟 G4 场景（scripts/gate4.sh：五种转场轮流、Overlay 1–4 动画、
#                   抠像开、多画面自定义布局；V1–V7、A1–A4、E1–E3、E5、C1–C4）→ reports/G4-run-10min.md + reports/G4.md，并写 baselines/g4-m5max.json
#                   （与 g3-m5max.json 比只作参考：底纹换成噪声、负载加了抠像 / 叠加，不可比）
# make gate4-run    只跑 10 分钟场景（跳过 L0 / L1）；make gate4-1h 60 分钟版（用户触发）
# make gate4-ndi    NDI 回环 L1（headless --ndi-send → NDIInput，60 s，reports/G4-ndi.md）；make gate4-matrix 编译矩阵三种配置（reports/G4-matrix.md）
# make gate4-report 只用已有产物重拼 reports/G4.md（改了 G4-notes.md 或跑完 gate4-ndi / gate4-matrix 之后用）
# E7–E9 沿用 G3（reports/G3-net.md，W3 五路没动推流）；C5 真 Companion 与 V8 / V9 的人工部分在 docs/checklists/G4.md。数据留在 .build/gate4/<label>/（不入库）。
# 后面的检查点复用这条流水线时别改 G4 的入库文件：make gate4-run GATE4_CHECKPOINT=G6 GATE4_PREVIOUS=baselines/g4-m5max.json GATE4_BASELINE=baselines/g6-m5max.json GATE4_LABEL=g6
#   → 运行报告 reports/G6-run-g6.md、基线 baselines/g6-m5max.json，reports/G4.md 与 g4 基线不动（G6 加；scripts/gate4.sh --checkpoint）
GATE4_BASELINE ?= baselines/g4-m5max.json
GATE4_PREVIOUS ?= baselines/g3-m5max.json
GATE4_CHECKPOINT ?= G4
GATE4_LABEL ?= 10min
.PHONY: gate4 gate4-run gate4-1h gate4-ndi gate4-matrix gate4-report
gate4: test-packages test-tools
	scripts/gate4.sh --minutes 10 --label $(GATE4_LABEL) --checkpoint $(GATE4_CHECKPOINT) --baseline $(GATE4_PREVIOUS) --write-baseline $(GATE4_BASELINE)

gate4-run:
	scripts/gate4.sh --minutes 10 --label $(GATE4_LABEL) --checkpoint $(GATE4_CHECKPOINT) --baseline $(GATE4_PREVIOUS) --write-baseline $(GATE4_BASELINE)

gate4-1h:
	scripts/gate4.sh --minutes 60 --label 1h --checkpoint $(GATE4_CHECKPOINT) --baseline $(GATE4_BASELINE)

gate4-ndi:
	scripts/gate4-ndi.sh
	$(MAKE) gate4-report

gate4-matrix:
	scripts/gate4-matrix.sh
	$(MAKE) gate4-report

gate4-report:
	scripts/gate4-report.sh --label 10min --baseline $(GATE4_PREVIOUS)

# ---------- W4-A 长稳与性能（prompt 70；脚本在 scripts/soak/、scripts/perf/，数据在 .build/soak/、.build/perf/，不入库）----------
# make soak           8 小时长稳（S1 / S2 / S3 / A3；§3 S1 的负载 + 内置摄像头 + 文件输入）→ reports/W4-soak-8h.md；接电源、无人值守、别跑 App 测试
# make soak-1h        每晚缩短版（1 小时）→ reports/W4-soak-1h.md
# make perf-baseline  L5：G4 场景 5 分钟（V1–V3、S3）+ E4（文件输入 → 编码 → 录制，libvmaf 对源），与同机同 macOS 大版本的上一版基线比，退步 > 10% 非零退出
# 参数：SOAK_ARGS='--powermetrics on --ambient "约 24 °C"'、PERF_ARGS='--powermetrics on'（powermetrics 要 sudo，会在终端里问一次密码）
# S2 的 Instruments Leaks（30 分钟）：scripts/soak/leaks.sh；S4 热降频（无风扇机型）：scripts/perf/s4-thermal.sh
SOAK_ARGS ?=
PERF_ARGS ?=
.PHONY: soak soak-1h perf-baseline
soak:
	scripts/soak/soak.sh --hours 8 --label 8h $(SOAK_ARGS)

soak-1h:
	scripts/soak/soak.sh --hours 1 --label 1h $(SOAK_ARGS)

perf-baseline:
	scripts/perf/perf-baseline.sh $(PERF_ARGS)

# ---------- W4-B 发布工程 ----------
# archive / archive-adhoc / release-verify / appcast / release-test / pin-check / pin-sync / runner-install：scripts/release/release.mk（归属 W4-B）
-include scripts/release/release.mk
