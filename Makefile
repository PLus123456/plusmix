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
