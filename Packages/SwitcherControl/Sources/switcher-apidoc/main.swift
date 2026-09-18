// switcher-apidoc —— 把 docs/api.md 打到标准输出：swift run --package-path Packages/SwitcherControl switcher-apidoc > docs/api.md
import SwitcherControl

print(APIDocument.markdown(), terminator: "")
