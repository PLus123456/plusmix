# 011 lint 禁词例外：兼容层的协议字面量

提出会话 / 分支：W3-D / w3-control2

改什么：`scripts/lint-rules.sh` 第 1 项（禁词）对 `Packages/SwitcherControl/Sources/VMixCompat/` 加一个受控例外：
允许 XML 根元素名这一个协议字面量（`StatusXML.rootElement`，`StatusXML.swift` 里唯一一处；测试引用这个常量，不重复写）。
建议的实现：lint 在扫描时把 `StatusXML.rootElement = "…"` 这一行（或带 `// lint:allow-protocol-literal` 标记的行）从命中里去掉；
其他任何形式（注释、文案、标识符）仍然不许。**不改 SwitcherContracts，不是契约变更**，放这里是因为这是"停下来问用户"的决策记录（README 第 3 条）。

为什么：Companion 的模块（以及所有对方生态的客户端）靠 XML 根元素名识别状态文档——`tcp.ts` 里 `startsWith('<vmix>') && endsWith('</vmix>')`，
不匹配就当未知消息丢掉，C5 六项全都过不了。这个名字是对方协议的一部分，没法改名；用字符串拼接绕过 lint 是自欺欺人，所以直接写字面量、让 lint 报出来、
在这里说明。目前 `make lint` 在本分支只有这一处禁词命中（`StatusXML.swift` 的常量行）。

影响谁：只有 `make lint` 的结果和 `scripts/lint-rules.sh`（G4 / P0 的目录）。代码不用改。

怎么迁移：用户批准后由检查点会话改 `scripts/lint-rules.sh`（加白名单行或标记），或者驳回——驳回的话兼容层的 XML 就没法被 Companion 识别，
等于 C5 做不了，需要用户另外决定兼容层的去留。

另：法律层面这一字面量属于"描述性使用对方名字"的一部分（设计方案 §0），发布前问律师时一并问。

状态：已批（用户 2026-09-19："这两个按照你的想法来"），W3-D 会话按用户授权落地：
`scripts/lint-rules.sh` 加例外 2（只放行 `Packages/SwitcherControl/Sources/VMixCompat/` 下同一行带 `lint:allow-protocol-literal` 标记的行，
标记出现在别的目录不算数），`StatusXML.swift` 的常量行加标记；`make lint BRANCH=w3-control2` 禁词检查绿。
