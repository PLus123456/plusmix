# W4-B 发布工程的 make 目标（根 Makefile 末尾 -include 本文件；PATH / SHELL 等变量沿用根 Makefile）。
# 用法：
#   make archive                     Team ID 从 DEVELOPMENT_TEAM 环境变量：xcodebuild archive → Developer ID 签名 → 校验 → DMG → 公证 + staple
#                                    没有 Developer ID 身份时自动退成 ad-hoc（除公证外全走一遍，报告里公证标 BLOCKED-账号）
#   make archive-adhoc               强制 ad-hoc、跳过公证（本机验证脚本 / CI 每次提交用）
#   make release-verify TARGET=x     校验一个 .app 或 .dmg（签名、spctl、staple、扩展、libndi、Sparkle）；VERIFY_FLAGS=--expect-notarized 要求已公证
#   make appcast DIR=dir APPCAST_FLAGS="--download-url-prefix https://…/"   用 Sparkle 的 generate_appcast 给目录里的 DMG 出 appcast.xml
#   make release-test                scripts/release/tests/（R1–R6、R11–R17；R17 = 开发签名真签，没有 Apple Development 身份时跳过）
#   make pin-check / pin-sync        依赖钉版本一致性检查 / 把模板拷进工作区（同 make gen 那一步）
#   make runner-install RUNNER_FLAGS="--url https://github.com/<owner>/<repo> --token <token>"   装 GitHub Actions self-hosted runner
# 产物：$(RELEASE_OUT)/<版本>/{PlusMix.xcarchive,PlusMix.app,PlusMix-<版本>.dmg,release-report.md,verify.json}（产物名 = project.yml 的 PRODUCT_NAME，W4-D）
RELEASE_OUT     ?= .build/release
RELEASE_SCRIPTS := scripts/release
ARCHIVE_FLAGS   ?=
VERIFY_FLAGS    ?=
APPCAST_FLAGS   ?=
RUNNER_FLAGS    ?=

.PHONY: archive archive-adhoc release-verify appcast release-test pin-check pin-sync runner-install sparkle-keys

archive:
	$(RELEASE_SCRIPTS)/archive.sh --out $(RELEASE_OUT) $(ARCHIVE_FLAGS)

archive-adhoc:
	$(RELEASE_SCRIPTS)/archive.sh --adhoc --skip-notarize --out $(RELEASE_OUT) $(ARCHIVE_FLAGS)

release-verify:
	@[ -n "$(TARGET)" ] || { echo "用法：make release-verify TARGET=<PlusMix.app 或 .dmg> [VERIFY_FLAGS=--expect-notarized]"; exit 2; }
	$(RELEASE_SCRIPTS)/verify.sh $(TARGET) $(VERIFY_FLAGS)

appcast:
	@[ -n "$(DIR)" ] || { echo "用法：make appcast DIR=<放 DMG 的目录> APPCAST_FLAGS=\"--download-url-prefix https://…/\""; exit 2; }
	$(RELEASE_SCRIPTS)/appcast.sh $(DIR) $(APPCAST_FLAGS)

release-test:
	$(RELEASE_SCRIPTS)/tests/run.sh

pin-check:
	$(RELEASE_SCRIPTS)/pin-deps.sh check

pin-sync:
	$(RELEASE_SCRIPTS)/pin-deps.sh sync

runner-install:
	$(RELEASE_SCRIPTS)/ci-runner-setup.sh $(RUNNER_FLAGS)

# 生成 / 查看 Sparkle 的 EdDSA 密钥（私钥进钥匙串，不进仓库）
sparkle-keys:
	$(RELEASE_SCRIPTS)/sparkle-keys.sh generate
