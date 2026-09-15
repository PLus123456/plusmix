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

# make lint 检查的分支：默认当前分支；检查别的分支用 make lint BRANCH=w1-core
BRANCH ?= $(shell git symbolic-ref --short -q HEAD 2>/dev/null || echo main)
# 会话新增的检查脚本：放 scripts/ 下、名字以 check- 或 lint- 开头就会自动挂进来（docs/OWNERSHIP.md 补充规则 4）
EXTRA_LINTS := $(filter-out scripts/lint-rules.sh scripts/check-deps.sh scripts/check-ownership.sh,\
                 $(wildcard scripts/lint-*.sh scripts/check-*.sh))

.PHONY: all gen build test lint clean help build-packages build-tools build-app test-packages test-tools test-app

all: gen build test lint

help:
	@echo "make gen    生成 $(XCODEPROJ)（XcodeGen；DEVELOPMENT_TEAM 环境变量可选）"
	@echo "make build  编译所有包、两个工具、App"
	@echo "make test   所有包 swift test + 两个工具跑一次冒烟 + App 的 xcodebuild test"
	@echo "make lint   scripts/lint-rules.sh + check-deps.sh + check-ownership.sh \$$BRANCH + scripts/{check,lint}-*.sh"
	@echo "make clean  删掉所有 .build 和生成的工程"

# ---------- gen ----------
gen:
	$(XCODEGEN) generate --quiet

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
test: test-packages test-tools test-app

test-packages:
	@for p in $(PACKAGES); do echo "== swift test $$p"; swift test --package-path $$p || exit 1; done

# 工具目前只打印版本；冒烟 = 编出来、跑得起、输出里有自己的名字和版本号
test-tools:
	@for t in $(TOOLS); do \
	  name=$$(basename $$t); echo "== smoke $$name"; \
	  swift build --package-path $$t || exit 1; \
	  bin="$$(swift build --package-path $$t --show-bin-path)/$$name"; \
	  out="$$($$bin)"; echo "   $$out"; \
	  echo "$$out" | grep -qE "^$$name [0-9]+\.[0-9]+\.[0-9]+" || { echo "   冒烟失败：$$bin 输出不含版本"; exit 1; }; \
	done

test-app: $(XCODEPROJ)/project.pbxproj
	@echo "== xcodebuild test $(SCHEME)"
	$(XCB) $(XCB_FLAGS) test

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
# make gate3-net  E7–E9：需要用户先在另一个终端 sudo scripts/netem.sh serve（scripts/gate3-net.sh 会检查代理是否在线）
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

