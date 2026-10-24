# Security Review: plusmix

## Scope

针对用户指定的网络部分开展仓库源码审计与隔离本地攻击模拟，覆盖默认控制 API、可选兼容 HTTP/TCP 与 tally、推流客户端、凭据传播和 Stream Deck 插件。

- Scan mode: repository
- Target kind: git_worktree
- Target ID: target_sha256_256a87cb49adf05048fb3b55b8ab8f8d0200d3939ae86aaed25843966b7f6c49
- Revision: 1f9be64028f680ab9abb363b53bcbcaa16a3fdf3
- Snapshot digest: codex-security-snapshot/v1:sha256:18f0beb9083fa6a91df8249d72da11131480acaadf5e0cb92549e29b976c822b
- Inventory strategy: repository
- Included paths: .
- Excluded paths: none
- Artifacts reviewed: artifacts/network-probe/results.txt, artifacts/network-probe/probe.py, artifacts/network-probe/main.swift, artifacts/network-probe/test-results.txt, artifacts/amf-probe/C06-evidence.txt, artifacts/amf-probe/C06-client.swift, artifacts/amf-probe/C06-server.py, artifacts/amf-probe/C06-crash.ips
- Scan context: 多 agent 并行交叉验证。12 项发现，其中 8 项新发现、4 项此前已记录。严重程度按本仓库默认配置、明确可选配置和攻击前提校准。

Limitations and exclusions:
- 未验证真实浏览器 Private Network Access/Local Network Access 策略；异源 WebSocket 结论为服务端接受和本地原始协议探针。
- 未评估实际用户的 LAN 监听、防火墙和是否配置 token。
- 第三方 NDI/SRT/HaishinKit/Sparkle 库内部解析器不在本轮源码审计范围。
- Excluded 非网络相关渲染、音频与 UI 实现: 用户指定网络攻击面；仅在网络输入到危险 sink 的必要路径追踪。
- Excluded 第三方 NDI/SRT/HaishinKit/Sparkle 内部解析器: 本轮审计应用仓库拥有的包装层和可见调用路径；没有对外部 SDK 源码做模糊测试。
- Excluded 真实浏览器私有网络策略、外部 LAN 部署与 GPU 全应用会话: 隔离环境只执行本地原始协议探针；实际浏览器和部署条件未提供，相关边界在发现的限制中说明。
- Excluded 非网络相关渲染、音频与 UI 实现: 用户指定网络攻击面；这些实现仅在构成网络输入到危险 sink 的必要路径时追踪。

### Scan Summary

| Field | Value |
| --- | --- |
| Scan outcome | completed |
| Reportable findings | 12 |
| Severity mix | high: 2, medium: 7, low: 3 |
| Confidence mix | high: 11, medium: 1 |
| Coverage | complete |
| Validation mode | 生产网络组件的本机协议探针、真实 RTMP 握手恶意回复、静态源到汇追踪和现有测试。 |

Canonical artifacts: `scan-manifest.json`, `findings.json`, and `coverage.json`. This report is a deterministic projection of those files.

## Threat Model

PlusMix App 默认在 127.0.0.1:8765 开启无令牌 HTTP/WebSocket 控制 API；headless 仅在显式 CLI 选项下开启。可选兼容层提供 HTTP GET/TCP 命令入口，可选 tally 提供只读 HTTP/WebSocket；推流和 NDI 经用户配置出入网络。信任边界和默认开关依据 AppSettings.swift:80-127、APIServer.swift:50-61、VMixCompatConfiguration.swift:11-20、TallyServer.swift:61-71 及 HeadlessCLI.swift:116-137。

### Assets

- 直播节目/预览、录制/推流状态与控制命令完整性
- MixerState 中的推流 URL 和 streamKey，以及 API token
- 网络推送媒体和来源输入帧

### Trust Boundaries

- 同机浏览器或进程可连默认回环 API；HTTP/WS 路由仅在配置 token 时安装鉴权，命令通过 CommandBus。AppSettings.swift:80-84；APIServer.swift:50-61,99-133,165-227,250-258。
- 启用兼容层后，HTTP/TCP 各自独立监听并提交命令；默认关闭且只监听 127.0.0.1，无独立 token。VMixCompatConfiguration.swift:11-20；CompatHTTPServer.swift:28-39,70-86；CompatTCPServer.swift:26-33,125-152。
- 启用 tally 后，默认监听 0.0.0.0，向可达客户端推送只读状态。AppSettings.swift:110-127；TallyServer.swift:61-71,107-145。
- 用户配置的 NDI/RTMP/SRT 端点是媒体网络边界；客户端 WebSocket/诊断导出可能接触推流配置。StreamDestination.swift:48-97；NDIInput.swift:238-271；APIModels.swift:171-194；DiagnosticBundle.swift:39-43,173-174。

### Attacker Capabilities

- 恶意网页可尝试连接本机回环 HTTP/WebSocket；能否成功须动态验证浏览器及服务端行为。
- 局域网攻击者只在监听地址、主机防火墙和操作者配置允许时可达，不能假定默认互联网暴露。
- 恶意流服务器可向配置的流客户端返回协议数据；本轮未假定攻击者能编辑本地 show、读取 token 或控制 Sparkle 签名密钥。

### Security Objectives

- 只有预期来源或持有配置 token 的客户端可读取敏感状态和改变直播控制状态。
- 每个可选监听器的鉴权、资源限制和只读范围清晰且独立。
- 用户配置的媒体目标及其中凭据不得非预期泄露；来自网络的报文解析应有资源上限。

### Assumptions

- 未提供实际部署、token、show、互联网暴露或外部服务策略；结论按默认配置及明确开启兼容层分别评估。
- NDI 行为取决于可选 SDK；Sparkle 更新 feed 和公钥由构建时配置，非本次主动入口。

## Findings

| Finding | Severity | Confidence | Detailed write-up |
| --- | --- | --- | --- |
| [已知：API 可接受 Int.max FTB 时长并在反转时崩溃](#finding-1) | high | medium | inline below |
| [新发现：默认本机 WebSocket 接受异源连接并执行命令](#finding-2) | high | high | inline below |
| [已知：API 状态响应和快照原样包含推流凭据](#finding-3) | medium | high | inline below |
| [新发现：恶意 RTMP 握手回复可使 AMF 解析器栈溢出崩溃](#finding-4) | medium | high | inline below |
| [新发现：兼容层 GET 在无来源校验下执行直播命令](#finding-5) | medium | high | inline below |
| [已知：API 超大输入编号使兼容层 TALLY/XML 构造失控](#finding-6) | medium | high | inline below |
| [新发现：兼容 TCP 长行可无界增长进程内存](#finding-7) | medium | high | inline below |
| [新发现：局域网控制令牌经明文 HTTP/WebSocket 传输](#finding-8) | medium | high | inline below |
| [已知：诊断包保留 RTMP URL 路径里的发布密钥](#finding-9) | medium | high | inline below |
| [新发现：畸形 WebSocket 快照可使 Stream Deck 插件退出](#finding-10) | low | high | inline below |
| [新发现：Stream Deck 插件把 API token 写入日志](#finding-11) | low | high | inline below |
| [新发现：编码后的敏感查询参数名绕过推流地址脱敏](#finding-12) | low | high | inline below |

### Confidence Scale

| Label | Meaning |
| --- | --- |
| high | Direct evidence supports the finding with no material unresolved blocker. |
| medium | Evidence supports a plausible issue, but material runtime or reachability proof remains. |
| low | Evidence is incomplete and the item is retained only for explicit follow-up. |

<a id="finding-1"></a>

### [1] 已知：API 可接受 Int.max FTB 时长并在反转时崩溃

| Field | Value |
| --- | --- |
| Severity | high |
| Confidence | medium |
| Confidence rationale | 直接 reducer 复现 SIGTRAP 和现有代码路径一致，HTTP 到真实 App 全链未测试。 |
| Category | Integer overflow in control command processing |
| CWE | CWE-190 |
| Affected lines | Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:116-129, Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:43-44, Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:76-79 |

#### Summary

上一轮 N03 已证实：控制命令把 FTB 时长设为 Int.max，特定电平反转使 Double(Int.max) 舍入到 2^63，再转换为 Int 触发陷阱。网络 API 的校验只拒绝负数。

#### Root Cause

命令入口没有约束 FTB 时长到可安全参与 Double→Int 回转的范围。setFTBDuration(Int.max) 被接受，equivalentStart 在反转时转换越界。

**FTB 时长只拒绝负数** — `Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:43`

Int.max 通过校验，进入状态机的 FTB 计算。

```swift
case .setFTBDuration(let ticks):
            return ticks < 0 ? "FTB 时长不能为负：\(ticks)" : nil
```

**浮点回转整数** — `Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:78`

极值 duration 在舍入后超过 Int 可表示范围，转换时陷阱。

```swift
let k = Int((progressed * Double(duration)).rounded())
```

#### Validation

前次 N03 复现默认状态 ftb(true)→setFTBDuration(Int.max)→ftb(false) 触发崩溃；本轮确认校验仍仅拒绝负数。

Validation method: 前次审查的直接 reducer SIGTRAP 复现加本轮网络入口源代码复核

**FTB 时长只拒绝负数** — `Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:43`

Int.max 通过校验，进入状态机的 FTB 计算。

```swift
case .setFTBDuration(let ticks):
            return ticks < 0 ? "FTB 时长不能为负：\(ticks)" : nil
```

**浮点回转整数** — `Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:78`

极值 duration 在舍入后超过 Int 可表示范围，转换时陷阱。

```swift
let k = Int((progressed * Double(duration)).rounded())
```

Limitations:
- 尚未在完整 App 进程执行 HTTP 端到端崩溃测试。

#### Dataflow

能提交控制命令的客户端先设极大时长，再操纵 FTB 反转，使 reducer 转整数时崩溃。

- **Source:** 已获控制 API 命令权限的客户端；默认回环无令牌配置下为同机调用者

- **Sink:** POST /api/v1/command 或 WS command

- **Outcome:** 导播进程陷阱退出

**FTB 时长只拒绝负数** — `Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:43`

Int.max 通过校验，进入状态机的 FTB 计算。

```swift
case .setFTBDuration(let ticks):
            return ticks < 0 ? "FTB 时长不能为负：\(ticks)" : nil
```

**浮点回转整数** — `Packages/SwitcherCore/Sources/SwitcherEngine/State/MixerReducer.swift:78`

极值 duration 在舍入后超过 Int 可表示范围，转换时陷阱。

```swift
let k = Int((progressed * Double(duration)).rounded())
```

#### Reachability

已获控制 API 命令权限的客户端；默认回环无令牌配置下为同机调用者 经 POST /api/v1/command 或 WS command，导播进程陷阱退出

- **Attacker:** 已获控制 API 命令权限的客户端；默认回环无令牌配置下为同机调用者

- **Entry point:** POST /api/v1/command 或 WS command

- **Outcome:** 导播进程陷阱退出

Preconditions:
- 攻击者须可提交控制 API 命令并达到触发反转的 FTB 状态；上一轮已做 reducer 复现但未跑 HTTP 到完整 App 的端到端崩溃。

Limitations:
- 尚未在完整 App 进程执行 HTTP 端到端崩溃测试。

#### Severity

**High** — 经已授权或默认无令牌控制 API 的命令序列可使直播进程崩溃；属于上一轮已知问题。

攻击者须可提交控制 API 命令并达到触发反转的 FTB 状态；上一轮已做 reducer 复现但未跑 HTTP 到完整 App 的端到端崩溃。

Impact assessment:
- **Level:** high
- **Why:** 经已授权或默认无令牌控制 API 的命令序列可使直播进程崩溃；属于上一轮已知问题。

Likelihood assessment:
- **Level:** medium
- **Why:** 攻击者须可提交控制 API 命令并达到触发反转的 FTB 状态；上一轮已做 reducer 复现但未跑 HTTP 到完整 App 的端到端崩溃。

#### Remediation

统一限制 FTB 时长到安全区间，并在 equivalentStart 使用有界/饱和数值转换。

Tests:
- 通过真实 API 发送极值时长应获 400 且进程继续服务。
- 覆盖 FTB 反转及临界最大安全时长。

<a id="finding-2"></a>

### [2] 新发现：默认本机 WebSocket 接受异源连接并执行命令

| Field | Value |
| --- | --- |
| Severity | high |
| Confidence | high |
| Confidence rationale | 源代码缺少 Origin 校验，且隔离实例带外部 Origin 的握手、状态读取与命令执行均成功；未验证所有浏览器的私有网络策略。 |
| Category | Cross-origin WebSocket hijacking |
| CWE | CWE-346 |
| Affected lines | App/Sources/AppSettings.swift:81-84, Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:52-55, Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:165-180, Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:220, Packages/SwitcherControl/Sources/SwitcherControl/API/APIModels.swift:193 |

#### Summary

默认 App 开启无令牌的回环控制 API。模拟外部 Origin 的 WebSocket 握手获 101，立即读取含测试推流密钥的状态快照，并成功提交 setPreview，随后状态变化。

#### Root Cause

跨来源网页不应凭默认无令牌回环监听获得完整控制权。AppSettings 默认开启回环 API，APIServer 只在 token 非空时安装鉴权，WebSocket 路由没有 Origin 决策，订阅后推送整份 MixerState，接收命令再交给 CommandBus。

**只有配置 token 才安装鉴权** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:52`

默认 nil 令牌使 HTTP/WS 中间件都不安装；下一步直接注册 WebSocket 路由。

```swift
if let token = configuration.token {
```

**WS 路由接受连接** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:166`

路由未读取或校验 Origin，连接后订阅状态并读取命令。

```swift
router.ws("/api/v1/events") { [self] inbound, outbound, _ in
```

**命令提交总线** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:220`

异源连接传入的命令到达直播控制总线。

```swift
let receipt = try await bus.submit(command, source: .api)
```

#### Validation

Origin=https://attacker.invalid 返回 HTTP 101；快照包含 scan-canary-only；setPreview 回执 applied=true，随后 GET state 的 preview=3。

Validation method: 隔离 CPU-only APIServer 的本机原始 WebSocket 握手与状态核对

**只有配置 token 才安装鉴权** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:52`

默认 nil 令牌使 HTTP/WS 中间件都不安装；下一步直接注册 WebSocket 路由。

```swift
if let token = configuration.token {
```

**WS 路由接受连接** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:166`

路由未读取或校验 Origin，连接后订阅状态并读取命令。

```swift
router.ws("/api/v1/events") { [self] inbound, outbound, _ in
```

**命令提交总线** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:220`

异源连接传入的命令到达直播控制总线。

```swift
let receipt = try await bus.submit(command, source: .api)
```

Limitations:
- 未使用真实浏览器测试 Private Network Access / Local Network Access 策略；只证实服务端接受异源 Origin。
- 完整 GPU 导播引擎不可用；测试使用生产控制服务与状态机。

#### Dataflow

恶意页面或同机低信任客户端发起带外部 Origin 的 WS 升级，读取快照并发送 JSON 命令，改变预览/节目或输出。

- **Source:** 能从受害主机发起回环 WebSocket 的低信任页面或进程

- **Sink:** GET /api/v1/events WebSocket 升级

- **Outcome:** 读取全量状态并执行控制命令

**只有配置 token 才安装鉴权** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:52`

默认 nil 令牌使 HTTP/WS 中间件都不安装；下一步直接注册 WebSocket 路由。

```swift
if let token = configuration.token {
```

**WS 路由接受连接** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:166`

路由未读取或校验 Origin，连接后订阅状态并读取命令。

```swift
router.ws("/api/v1/events") { [self] inbound, outbound, _ in
```

**命令提交总线** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:220`

异源连接传入的命令到达直播控制总线。

```swift
let receipt = try await bus.submit(command, source: .api)
```

#### Reachability

能从受害主机发起回环 WebSocket 的低信任页面或进程 经 GET /api/v1/events WebSocket 升级，读取全量状态并执行控制命令

- **Attacker:** 能从受害主机发起回环 WebSocket 的低信任页面或进程

- **Entry point:** GET /api/v1/events WebSocket 升级

- **Outcome:** 读取全量状态并执行控制命令

Preconditions:
- 需要攻击者能让受害主机上的客户端发起到 127.0.0.1 的 WebSocket；浏览器私有网络限制可能影响具体网页可达性。配置 token 后该无令牌路径被中间件挡住。

Limitations:
- 未使用真实浏览器测试 Private Network Access / Local Network Access 策略；只证实服务端接受异源 Origin。
- 完整 GPU 导播引擎不可用；测试使用生产控制服务与状态机。

#### Severity

**High** — 默认启用的回环控制口可在异源连接建立后读取敏感状态并改变直播控制；凭据暴露和节目切换均已在隔离实例观察到。

需要攻击者能让受害主机上的客户端发起到 127.0.0.1 的 WebSocket；浏览器私有网络限制可能影响具体网页可达性。配置 token 后该无令牌路径被中间件挡住。

Impact assessment:
- **Level:** high
- **Why:** 默认启用的回环控制口可在异源连接建立后读取敏感状态并改变直播控制；凭据暴露和节目切换均已在隔离实例观察到。

Likelihood assessment:
- **Level:** medium
- **Why:** 需要攻击者能让受害主机上的客户端发起到 127.0.0.1 的 WebSocket；浏览器私有网络限制可能影响具体网页可达性。配置 token 后该无令牌路径被中间件挡住。

#### Remediation

对 WebSocket 升级实施明确的可信 Origin 白名单，并对可改变直播状态的客户端要求不可由跨来源页面自动取得的鉴权。

Tests:
- 在默认配置下外部 Origin 的 WS 升级应被拒绝，可信本机客户端仍可连接。
- 未授权连接不能收到状态快照，也不能执行 setPreview/Cut。

<a id="finding-3"></a>

### [3] 已知：API 状态响应和快照原样包含推流凭据

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 仓库问题单与源代码一致，隔离 WebSocket 快照实见测试密钥。 |
| Category | Exposure of sensitive information |
| CWE | CWE-200 |
| Affected lines | Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:100, Packages/SwitcherControl/Sources/SwitcherControl/API/APIModels.swift:181-193, Packages/SwitcherCore/Sources/SwitcherContracts/MixerState.swift:604-634 |

#### Summary

已在 W5D 问题单记录；GET /api/v1/state 与 WebSocket 快照直接序列化 MixerState，outputs\[\].settings.stream.url/streamKey 原样发给可访问 API 的客户端。本机隔离快照证实测试密钥可见。

#### Root Cause

公开给控制客户端的状态模型与包含密钥的配置模型复用同一 MixerState，序列化前没有去除流地址凭据或 streamKey。

**快照编码整份状态** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIModels.swift:193`

MixerState 内的 outputs.stream 字段随快照发送给状态订阅者。

```swift
try c.encode(state, forKey: .state)
```

#### Validation

本机快照 outputs.stream.streamKey 等于 scan-canary-only；已知问题单 W5D-w2-control-api-state-exposes-stream-credentials.md 描述相同路径。

Validation method: 已知问题单、源代码及本机快照验证

**快照编码整份状态** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIModels.swift:193`

MixerState 内的 outputs.stream 字段随快照发送给状态订阅者。

```swift
try c.encode(state, forKey: .state)
```

Limitations:
- 此次只使用虚构测试密钥。

#### Dataflow

可读取 API 状态的客户端调用 GET state 或订阅 WS，取得流地址与推流密钥。

- **Source:** 可访问 API 的客户端或默认回环中的同机进程

- **Sink:** GET /api/v1/state 或 WS /api/v1/events

- **Outcome:** 取得推流凭据

**快照编码整份状态** — `Packages/SwitcherControl/Sources/SwitcherControl/API/APIModels.swift:193`

MixerState 内的 outputs.stream 字段随快照发送给状态订阅者。

```swift
try c.encode(state, forKey: .state)
```

#### Reachability

可访问 API 的客户端或默认回环中的同机进程 经 GET /api/v1/state 或 WS /api/v1/events，取得推流凭据

- **Attacker:** 可访问 API 的客户端或默认回环中的同机进程

- **Entry point:** GET /api/v1/state 或 WS /api/v1/events

- **Outcome:** 取得推流凭据

Preconditions:
- 需要可访问 API 的客户端；默认回环，设置 token 可限制无凭据读者但不能阻止已授权客户端读取原文。

Limitations:
- 此次只使用虚构测试密钥。

#### Severity

**Medium** — 可读取控制 API 状态的客户端能获得推流发布密钥，局域网无令牌配置会扩大读者范围。

需要可访问 API 的客户端；默认回环，设置 token 可限制无凭据读者但不能阻止已授权客户端读取原文。

Impact assessment:
- **Level:** medium
- **Why:** 可读取控制 API 状态的客户端能获得推流发布密钥，局域网无令牌配置会扩大读者范围。

Likelihood assessment:
- **Level:** medium
- **Why:** 需要可访问 API 的客户端；默认回环，设置 token 可限制无凭据读者但不能阻止已授权客户端读取原文。

#### Remediation

为 API 状态输出建立独立公开 DTO，遮盖 streamKey 和 URL 凭据；读取原值需单独严格授权。

Tests:
- GET/WS 状态快照均不含虚构测试密钥。
- 确需编辑推流配置的专用接口进行单独鉴权。

<a id="finding-4"></a>

### [4] 新发现：恶意 RTMP 握手回复可使 AMF 解析器栈溢出崩溃

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 独立 agent 使用生产 SwitcherStreaming.o、真实回环 RTMP 握手及恶意回复复现进程 SIGBUS；崩溃栈显示反复经过 Reader.value:413 与 reply:353。 |
| Category | Uncontrolled recursion in AMF parser |
| CWE | CWE-674 |
| Affected lines | Packages/SwitcherOutputs/Sources/Streaming/HaishinKitTransport.swift:117-119, Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:349-355, Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:401-413 |

#### Summary

配置带用户名密码的 RTMP 推流地址时，客户端在发布前解析服务器发来的 Adobe 鉴权回复。AMF0 严格数组可递归嵌套而无深度限制；本机恶意 RTMP 服务端发送约 500 KB、10 万层嵌套数组后，客户端以 SIGBUS 退出。

#### Root Cause

RTMP Adobe 鉴权在消费远端 _result 时，用递归 Reader.value 解析 AMF0 数组和对象；未限制嵌套深度或采用迭代解析。消息总体长度可容纳约 10 万层单元素严格数组，解析先于超时保护同步执行。

**发布前解析鉴权回复** — `Packages/SwitcherOutputs/Sources/Streaming/HaishinKitTransport.swift:119`

带 userinfo 的 RTMP 推流目标在连接前进入 Adobe 鉴权分支，读取服务端消息。

```swift
target = try await RTMPAdobeAuth.authorize(connectURL: target, credentials: credentials, timeoutSeconds: Double(connectTimeout))
```

**解析服务端 AMF 命令对象** — `Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:353`

_result 的第三个 AMF 值即使结果随后被忽略也会完整递归解析。

```swift
_ = try r.value()
```

**严格数组递归无深度上限** — `Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:413`

攻击者可构造单元素严格数组反复嵌套，直到栈保护页触发崩溃。

```swift
for _ in 0..<(try u32()) { items.append(try value()) }
```

#### Validation

100 层同结构回复进入可捕获的服务器拒绝分支；10 万层、500020 字节回复令客户端退出码 138（SIGBUS）。崩溃报告为栈保护页 EXC_BAD_ACCESS，重复 Reader.value:413 后经 reply:353、exchange:207、probeConnect:117 到 authorize:56。

Validation method: 独立 agent 使用生产 SwitcherStreaming.o 与本机恶意 RTMP 服务器完成握手并注入 AMF0 回复

**发布前解析鉴权回复** — `Packages/SwitcherOutputs/Sources/Streaming/HaishinKitTransport.swift:119`

带 userinfo 的 RTMP 推流目标在连接前进入 Adobe 鉴权分支，读取服务端消息。

```swift
target = try await RTMPAdobeAuth.authorize(connectURL: target, credentials: credentials, timeoutSeconds: Double(connectTimeout))
```

**解析服务端 AMF 命令对象** — `Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:353`

_result 的第三个 AMF 值即使结果随后被忽略也会完整递归解析。

```swift
_ = try r.value()
```

**严格数组递归无深度上限** — `Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:413`

攻击者可构造单元素严格数组反复嵌套，直到栈保护页触发崩溃。

```swift
for _ in 0..<(try u32()) { items.append(try value()) }
```

Limitations:
- 完整 App UI 未启动；使用已构建的生产库 API 与真实本机网络路径。
- RTMPS 共用解析器，但未对 TLS 链路做动态复现。

#### Dataflow

恶意 RTMP 目标或明文链路主动攻击者在 Adobe 鉴权 _result 的第三个 AMF 值中嵌入深层严格数组，触发 Reader.value 无限递归并使进程崩溃。

- **Source:** 远端 RTMP 服务端发送的 type-20 AMF 命令回复

- **Sink:** RTMPAdobeAuth.Reader.value 递归解析

- **Outcome:** 进程 SIGBUS 崩溃，推流中断

**发布前解析鉴权回复** — `Packages/SwitcherOutputs/Sources/Streaming/HaishinKitTransport.swift:119`

带 userinfo 的 RTMP 推流目标在连接前进入 Adobe 鉴权分支，读取服务端消息。

```swift
target = try await RTMPAdobeAuth.authorize(connectURL: target, credentials: credentials, timeoutSeconds: Double(connectTimeout))
```

**解析服务端 AMF 命令对象** — `Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:353`

_result 的第三个 AMF 值即使结果随后被忽略也会完整递归解析。

```swift
_ = try r.value()
```

**严格数组递归无深度上限** — `Packages/SwitcherOutputs/Sources/Streaming/RTMPAdobeAuth.swift:413`

攻击者可构造单元素严格数组反复嵌套，直到栈保护页触发崩溃。

```swift
for _ in 0..<(try u32()) { items.append(try value()) }
```

#### Reachability

配置含用户名密码的 RTMP 推流地址，服务端回复被 Adobe 鉴权解析器接受。

- **Attacker:** 恶意推流服务器或明文 RTMP 路径的主动攻击者

- **Entry point:** RTMP _result 回复的第三个 AMF0 值

- **Outcome:** 进程 SIGBUS 崩溃，推流中断

Preconditions:
- 目标推流地址包含 userinfo，进入 Adobe 鉴权分支。
- 攻击者能提供格式合法的 RTMP 握手与命令回复。

Limitations:
- 完整 App UI 未启动；RTMPS 动态路径未验证。

#### Severity

**Medium** — 可由恶意推流服务端或明文 RTMP 链路上的主动攻击者稳定使推流进程崩溃；需用户配置带凭据的 RTMP 目标，非默认暴露的入站接口。

实际 RTMP/RTMPS Adobe 鉴权解析路径共用；只对明文 RTMP 做了端到端动态复现。攻击者需控制目标服务端或链路上的有效响应。

Impact assessment:
- **Level:** medium
- **Why:** 生产库的真实 RTMP 网络路径在约 500 KB 输入下进程崩溃。

Likelihood assessment:
- **Level:** low
- **Why:** 需要恶意 RTMP 目标或主动链路控制，且用户使用带凭据的 Adobe 鉴权地址。

#### Remediation

对 AMF0 递归值解析设置严格最大嵌套深度与元素预算；超限抛出可处理的协议错误，并考虑迭代解析避免调用栈依赖输入深度。

Tests:
- 真实回环 RTMP 服务端回复超深严格数组时，客户端应返回协议错误而非崩溃。
- 正常 Adobe 鉴权 _result、嵌套边界及 RTMPS 共用解析路径均应回归。

<a id="finding-5"></a>

### [5] 新发现：兼容层 GET 在无来源校验下执行直播命令

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 生产兼容 HTTP 路由和总线在隔离实例下实测外部 Origin 的 GET 使 program 变化。 |
| Category | Cross-site request forgery |
| CWE | CWE-352 |
| Affected lines | Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:30-33, Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:70-80, Packages/SwitcherControl/Sources/VMixCompat/VMixCompatServer.swift:202-215 |

#### Summary

显式启用兼容层后，带外部 Origin 的 GET /api?Function=Cut 返回 200 OK Cut，隔离状态机的 program 变更。该入口没有 token 或来源校验。

#### Root Cause

兼容协议将状态变更放在 GET 查询串中，没有认证和 Origin 校验；启用后收到 Function 参数即调用 core.execute，再向 CommandBus 提交。

**状态变化绑定 GET** — `Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:31`

浏览器可触发的 GET 被绑定到兼容层处理函数。

```swift
router.get(RouterPath(path)) { [core] request, _ in
```

**查询函数直接执行** — `Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:80`

未校验 Origin 或会话权限，直接把请求翻译为控制命令。

```swift
let outcome = await core.execute(function)
```

#### Validation

Origin=https://attacker.invalid 的 GET /api?Function=Cut 返回 200 OK Cut；之后主 API state 的 program=3。

Validation method: 隔离 VMixCompatServer 本机 HTTP 请求

**状态变化绑定 GET** — `Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:31`

浏览器可触发的 GET 被绑定到兼容层处理函数。

```swift
router.get(RouterPath(path)) { [core] request, _ in
```

**查询函数直接执行** — `Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:80`

未校验 Origin 或会话权限，直接把请求翻译为控制命令。

```swift
let outcome = await core.execute(function)
```

Limitations:
- 真实浏览器 PNA 策略未验证。

#### Dataflow

攻击者使可达兼容层的客户端请求带 Function 的 GET，服务端把它当控制命令执行。

- **Source:** 可诱导操作员请求兼容层的页面，或可达兼容端口的网络客户端

- **Sink:** GET /api?Function=...

- **Outcome:** 更改节目或停止输出

**状态变化绑定 GET** — `Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:31`

浏览器可触发的 GET 被绑定到兼容层处理函数。

```swift
router.get(RouterPath(path)) { [core] request, _ in
```

**查询函数直接执行** — `Packages/SwitcherControl/Sources/VMixCompat/CompatHTTPServer.swift:80`

未校验 Origin 或会话权限，直接把请求翻译为控制命令。

```swift
let outcome = await core.execute(function)
```

#### Reachability

可诱导操作员请求兼容层的页面，或可达兼容端口的网络客户端 经 GET /api?Function=...，更改节目或停止输出

- **Attacker:** 可诱导操作员请求兼容层的页面，或可达兼容端口的网络客户端

- **Entry point:** GET /api?Function=...

- **Outcome:** 更改节目或停止输出

Preconditions:
- 必须显式启用兼容层；网页攻击受浏览器私有网络请求策略影响，局域网攻击还需监听地址和防火墙可达。

Limitations:
- 真实浏览器 PNA 策略未验证。

#### Severity

**Medium** — 启用兼容层的操作员可被跨站请求触发切换、停止录制或推流；组件默认关闭降低普遍暴露。

必须显式启用兼容层；网页攻击受浏览器私有网络请求策略影响，局域网攻击还需监听地址和防火墙可达。

Impact assessment:
- **Level:** medium
- **Why:** 启用兼容层的操作员可被跨站请求触发切换、停止录制或推流；组件默认关闭降低普遍暴露。

Likelihood assessment:
- **Level:** medium
- **Why:** 必须显式启用兼容层；网页攻击受浏览器私有网络请求策略影响，局域网攻击还需监听地址和防火墙可达。

#### Remediation

给兼容层添加独立鉴权及浏览器来源限制，并将状态变更改为受保护的非 GET 操作；保留协议兼容需求时至少提供可配置的显式可信客户端范围。

Tests:
- 跨来源 GET Function=Cut 应拒绝且节目不变。
- 无鉴权的局域网调用在启用安全模式时应拒绝。

<a id="finding-6"></a>

### [6] 已知：API 超大输入编号使兼容层 TALLY/XML 构造失控

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 当前代码的上限缺失和按最大编号分配/遍历均与已知问题文档一致。 |
| Category | Uncontrolled resource consumption |
| CWE | CWE-400 |
| Affected lines | Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:72-75, Packages/SwitcherControl/Sources/VMixCompat/TallyDigits.swift:7-12, Packages/SwitcherControl/Sources/VMixCompat/StatusXML.swift:22-24 |

#### Summary

docs/KNOWN_ISSUES.md:37 已记录：API addInput 仅校验编号大于零，兼容层 TALLY 与 XML 按最大编号预分配和逐号枚举；极大编号可导致卡死或分配失败。

#### Root Cause

输入编号缺少契约上界，而兼容层把最大编号当作数组/字符串长度和循环次数。API addInput 能构造与实际输入数量不成比例的状态。

**只检查输入编号下界** — `Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:73`

极大正整数能进入输入表，后续兼容状态使用它作为最大编号。

```swift
if config.number <= MixerState.noInput { return "输入编号必须 ≥ 1：\(config.number)" }
```

**TALLY 容量按最大编号** — `Packages/SwitcherControl/Sources/VMixCompat/TallyDigits.swift:11`

编号不是输入数；稀疏极大编号也会触发大分配。

```swift
s.reserveCapacity(maxNumber)
```

#### Validation

docs/KNOWN_ISSUES.md:37 已记录；CommandValidator.swift:72-75 无上界，TallyDigits.swift:7-12 与 StatusXML.swift:22-24 按最大编号执行。

Validation method: 已知问题文档与当前静态代码复核

**只检查输入编号下界** — `Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:73`

极大正整数能进入输入表，后续兼容状态使用它作为最大编号。

```swift
if config.number <= MixerState.noInput { return "输入编号必须 ≥ 1：\(config.number)" }
```

**TALLY 容量按最大编号** — `Packages/SwitcherControl/Sources/VMixCompat/TallyDigits.swift:11`

编号不是输入数；稀疏极大编号也会触发大分配。

```swift
s.reserveCapacity(maxNumber)
```

Limitations:
- 为避免 OOM，未发送极大编号做动态攻击。

#### Dataflow

有权提交 API 命令的客户端添加稀疏极大编号输入，随后兼容 TALLY/XML 请求导致分配或遍历失控。

- **Source:** 有 API 命令权限且兼容层开启时的控制客户端

- **Sink:** POST /api/v1/command addInput 后 GET /api 或 TCP TALLY/XML

- **Outcome:** 内存/CPU 耗尽或进程崩溃

**只检查输入编号下界** — `Packages/SwitcherControl/Sources/SwitcherControl/CommandBus/CommandValidator.swift:73`

极大正整数能进入输入表，后续兼容状态使用它作为最大编号。

```swift
if config.number <= MixerState.noInput { return "输入编号必须 ≥ 1：\(config.number)" }
```

**TALLY 容量按最大编号** — `Packages/SwitcherControl/Sources/VMixCompat/TallyDigits.swift:11`

编号不是输入数；稀疏极大编号也会触发大分配。

```swift
s.reserveCapacity(maxNumber)
```

#### Reachability

有 API 命令权限且兼容层开启时的控制客户端 经 POST /api/v1/command addInput 后 GET /api 或 TCP TALLY/XML，内存/CPU 耗尽或进程崩溃

- **Attacker:** 有 API 命令权限且兼容层开启时的控制客户端

- **Entry point:** POST /api/v1/command addInput 后 GET /api 或 TCP TALLY/XML

- **Outcome:** 内存/CPU 耗尽或进程崩溃

Preconditions:
- 需有 API 命令权限并显式启用兼容层；未执行危险规模的动态测试。

Limitations:
- 为避免 OOM，未发送极大编号做动态攻击。

#### Severity

**Medium** — 同时启用 API 与兼容层时，控制客户端可用一个极大输入编号诱发高内存或长时间循环，影响直播。

需有 API 命令权限并显式启用兼容层；未执行危险规模的动态测试。

Impact assessment:
- **Level:** medium
- **Why:** 同时启用 API 与兼容层时，控制客户端可用一个极大输入编号诱发高内存或长时间循环，影响直播。

Likelihood assessment:
- **Level:** medium
- **Why:** 需有 API 命令权限并显式启用兼容层；未执行危险规模的动态测试。

#### Remediation

在输入契约与 CommandValidator/reducer 同时限制编号范围，并使兼容序列化的资源使用与真实输入数量有界。

Tests:
- API 对超范围 addInput 返回 400。
- 兼容 TALLY/XML 面对稀疏输入保持有界资源。

<a id="finding-7"></a>

### [7] 新发现：兼容 TCP 长行可无界增长进程内存

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 源代码明确无行长上限，有界本机发送和 RSS 增长观测支持实际资源消耗。 |
| Category | Uncontrolled resource consumption |
| CWE | CWE-400 |
| Affected lines | Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:44-50, Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:104-118 |

#### Summary

启用兼容 TCP 时，一个连接持续发送无换行数据，readLoop 把每个块追加到 pending。隔离探针发送 2 MiB 后，服务进程 RSS 增长约 4.2 MiB。

#### Root Cause

行协议解析没有最大行长、并发连接限制或空闲超时。每个连接在 pending 中保留全部未换行字节，数组大小由对端决定。

**未换行字节直接累积** — `Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:110`

每次 TCP 读取把对端字节加入连接私有数组；未限制长度。

```swift
pending.append(contentsOf: buffer.readableBytesView)
```

**只有换行才清除** — `Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:111`

无换行数据不会进入消费分支，内存持续保留。

```swift
while let newline = pending.firstIndex(of: 0x0A) {
```

#### Validation

发送 2,097,152 字节无换行；RSS 从 20,922,368 增至 25,133,056 字节，增加 4,210,688 字节。

Validation method: 本机有界 TCP 探针与进程 RSS 采样

**未换行字节直接累积** — `Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:110`

每次 TCP 读取把对端字节加入连接私有数组；未限制长度。

```swift
pending.append(contentsOf: buffer.readableBytesView)
```

**只有换行才清除** — `Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:111`

无换行数据不会进入消费分支，内存持续保留。

```swift
while let newline = pending.firstIndex(of: 0x0A) {
```

Limitations:
- 只证明有界增长，未跑 OOM 攻击。

#### Dataflow

可达的客户端连接兼容 TCP 端口，持续发送未终止的行并保持连接，消耗导播进程内存。

- **Source:** 可连接已启用兼容 TCP 端口的客户端

- **Sink:** TCP 文本协议 8099 或配置端口

- **Outcome:** 进程内存持续增长，可能使直播不可用

**未换行字节直接累积** — `Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:110`

每次 TCP 读取把对端字节加入连接私有数组；未限制长度。

```swift
pending.append(contentsOf: buffer.readableBytesView)
```

**只有换行才清除** — `Packages/SwitcherControl/Sources/VMixCompat/CompatTCPServer.swift:111`

无换行数据不会进入消费分支，内存持续保留。

```swift
while let newline = pending.firstIndex(of: 0x0A) {
```

#### Reachability

可连接已启用兼容 TCP 端口的客户端 经 TCP 文本协议 8099 或配置端口，进程内存持续增长，可能使直播不可用

- **Attacker:** 可连接已启用兼容 TCP 端口的客户端

- **Entry point:** TCP 文本协议 8099 或配置端口

- **Outcome:** 进程内存持续增长，可能使直播不可用

Preconditions:
- 必须启用兼容 TCP 且攻击者可连接；探针只发送 2 MiB，未实施耗尽内存测试。

Limitations:
- 只证明有界增长，未跑 OOM 攻击。

#### Severity

**Medium** — 可达兼容端口的客户端能按连接持续放大内存占用，最终可中断直播进程；兼容层默认关闭。

必须启用兼容 TCP 且攻击者可连接；探针只发送 2 MiB，未实施耗尽内存测试。

Impact assessment:
- **Level:** medium
- **Why:** 可达兼容端口的客户端能按连接持续放大内存占用，最终可中断直播进程；兼容层默认关闭。

Likelihood assessment:
- **Level:** medium
- **Why:** 必须启用兼容 TCP 且攻击者可连接；探针只发送 2 MiB，未实施耗尽内存测试。

#### Remediation

设置最大行长度、连接数和读空闲期限；超过上限立即关闭连接。

Tests:
- 发送超过上限的无换行数据应断开连接且内存保持有界。
- 多连接闲置和长行压力下服务仍能处理正常命令。

<a id="finding-8"></a>

### [8] 新发现：局域网控制令牌经明文 HTTP/WebSocket 传输

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 服务端配置为 HTTP/1 WebSocket 升级，客户端代码明确为 ws:// 和查询串 token；未实测被动抓包。 |
| Category | Cleartext transmission of sensitive information |
| CWE | CWE-319 |
| Affected lines | App/Sources/AppSettings.swift:207-212, Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:59-61, Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:28-30, Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:256 |

#### Summary

用户把 API 开放到局域网且配置 token 后，服务端仍只提供 HTTP/WS；Stream Deck 固定构造 ws://...?token= 并发送 bearer 凭据。能观察该 LAN 连接的攻击者可取得并重放令牌。

#### Root Cause

API 的非回环监听配置没有 TLS 终止，Stream Deck 客户端固定选择明文 ws://，而同一 URL 的查询串承载可重放 token。

**插件以 ws 明文连接并带 token** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:29`

配置 token 被编码进连接 URL，下一行固定使用 ws 协议。

```javascript
const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
```

**未选择 wss** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:30`

局域网连接上的请求目标和后续帧不受传输加密保护。

```javascript
return `ws://${this.host}:${this.port}/api/v1/events${q}`;
```

#### Validation

App 允许非回环监听；APIServer 构造 HTTP1 WebSocket 服务；插件始终生成 ws:// 且在查询串加入 token；中间件接受该查询串。

Validation method: 静态协议与配置路径验证

**插件以 ws 明文连接并带 token** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:29`

配置 token 被编码进连接 URL，下一行固定使用 ws 协议。

```javascript
const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
```

**未选择 wss** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:30`

局域网连接上的请求目标和后续帧不受传输加密保护。

```javascript
return `ws://${this.host}:${this.port}/api/v1/events${q}`;
```

Limitations:
- 未抓取真实局域网流量；能否观察链路取决于部署。

#### Dataflow

操作员启用局域网控制，插件以明文 URL 携带 token 建立连接，链路观察者取得并重放。

- **Source:** 可观察远端控制链路的局域网攻击者

- **Sink:** 非回环 API HTTP/WebSocket 连接

- **Outcome:** 获得 token 后读取状态、提交命令

**插件以 ws 明文连接并带 token** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:29`

配置 token 被编码进连接 URL，下一行固定使用 ws 协议。

```javascript
const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
```

**未选择 wss** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:30`

局域网连接上的请求目标和后续帧不受传输加密保护。

```javascript
return `ws://${this.host}:${this.port}/api/v1/events${q}`;
```

#### Reachability

可观察远端控制链路的局域网攻击者 经 非回环 API HTTP/WebSocket 连接，获得 token 后读取状态、提交命令

- **Attacker:** 可观察远端控制链路的局域网攻击者

- **Entry point:** 非回环 API HTTP/WebSocket 连接

- **Outcome:** 获得 token 后读取状态、提交命令

Preconditions:
- 默认仅监听 127.0.0.1；需要用户改为非回环监听、令牌已配置且攻击者位于可观察的网络链路。

Limitations:
- 未抓取真实局域网流量；能否观察链路取决于部署。

#### Severity

**Medium** — 监听局域网时控制令牌与完整状态可在链路上被读取并重放，令牌鉴权不能抵御同链路观察者。

默认仅监听 127.0.0.1；需要用户改为非回环监听、令牌已配置且攻击者位于可观察的网络链路。

Impact assessment:
- **Level:** medium
- **Why:** 监听局域网时控制令牌与完整状态可在链路上被读取并重放，令牌鉴权不能抵御同链路观察者。

Likelihood assessment:
- **Level:** medium
- **Why:** 默认仅监听 127.0.0.1；需要用户改为非回环监听、令牌已配置且攻击者位于可观察的网络链路。

#### Remediation

为远程控制提供 HTTPS/WSS 或要求受保护隧道；避免在 URL 中承载令牌，并在 UI 明确阻止或提醒明文局域网配置。

Tests:
- 远程模式只允许经 TLS/WSS 连接，插件不得回退到 ws://。
- 日志和握手 URL 不包含 bearer 凭据。

<a id="finding-9"></a>

### [9] 已知：诊断包保留 RTMP URL 路径里的发布密钥

| Field | Value |
| --- | --- |
| Severity | medium |
| Confidence | high |
| Confidence rationale | 源码配置解析与脱敏行为清楚，仓库问题单已记录，未用真实服务商密钥验证。 |
| Category | Sensitive data exposure in diagnostics |
| CWE | CWE-200 |
| Affected lines | Packages/SwitcherOutputs/Sources/Streaming/StreamDestination.swift:60-69, Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:18-19, App/Sources/Release/ShowRedaction.swift:25-30, App/Sources/Release/DiagnosticBundle.swift:173 |

#### Summary

已在 W5D 问题单记录：streamKey 字段留空时 RTMP URL 末段作为发布名，但地址脱敏保留路径；分享诊断包会带出该发布密钥。

#### Root Cause

诊断脱敏函数不知道 StreamDestination 把 RTMP URL 末尾路径段当发布密钥使用，因此导出时保留该段。

**脱敏保留路径** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:19`

函数只处理 userinfo 和查询串，没有遮盖作为发布名的路径末段。

```swift
return redactQuery(out, marker: marker)
```

#### Validation

W5D-w4-release-diagnostics-stream-key-in-url-path.md 与当前 StreamDestination/ShowRedaction/DiagnosticBundle 实现一致。

Validation method: 已知问题单和静态数据流复核

**脱敏保留路径** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:19`

函数只处理 userinfo 和查询串，没有遮盖作为发布名的路径末段。

```swift
return redactQuery(out, marker: marker)
```

Limitations:
- 实际泄漏影响取决于目的地服务商是否将发布名视为秘密以及是否分享 ZIP。

#### Dataflow

运营者使用含路径密钥的 RTMP URL，导出诊断包并分享，接收者从 show JSON 中读取密钥。

- **Source:** 得到诊断 ZIP 的非预期接收者

- **Sink:** 诊断包 show.switcher.json

- **Outcome:** 获取流发布密钥

**脱敏保留路径** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:19`

函数只处理 userinfo 和查询串，没有遮盖作为发布名的路径末段。

```swift
return redactQuery(out, marker: marker)
```

#### Reachability

得到诊断 ZIP 的非预期接收者 经 诊断包 show.switcher.json，获取流发布密钥

- **Attacker:** 得到诊断 ZIP 的非预期接收者

- **Entry point:** 诊断包 show.switcher.json

- **Outcome:** 获取流发布密钥

Preconditions:
- 需要把发布密钥放在 RTMP URL 路径、操作者导出并分享诊断包，且服务端把该路径段作为秘密。

Limitations:
- 实际泄漏影响取决于目的地服务商是否将发布名视为秘密以及是否分享 ZIP。

#### Severity

**Medium** — 分享导出诊断包时可能把仍可用的推流发布密钥交给非预期接收者。

需要把发布密钥放在 RTMP URL 路径、操作者导出并分享诊断包，且服务端把该路径段作为秘密。

Impact assessment:
- **Level:** medium
- **Why:** 分享导出诊断包时可能把仍可用的推流发布密钥交给非预期接收者。

Likelihood assessment:
- **Level:** medium
- **Why:** 需要把发布密钥放在 RTMP URL 路径、操作者导出并分享诊断包，且服务端把该路径段作为秘密。

#### Remediation

诊断导出时按 RTMP 解析规则，在独立 streamKey 为空时遮盖作为 publish name 的 URL 末段。

Tests:
- 含路径发布密钥的 show 导出后 ZIP 内不得出现原文。

<a id="finding-10"></a>

### [10] 新发现：畸形 WebSocket 快照可使 Stream Deck 插件退出

| Field | Value |
| --- | --- |
| Severity | low |
| Confidence | high |
| Confidence rationale | 独立 Node 复现使用原始 SwitcherClient/tally.js 与假 WebSocket，畸形快照导致未捕获 TypeError 及进程退出码1；未运行 Stream Deck 宿主。 |
| Category | Improper validation of network message structure |
| CWE | CWE-20 |
| Affected lines | Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:96-105, Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/bin/plugin.js:15-21, Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/tally.js:32-34 |

#### Summary

插件连到恶意或遭篡改的 API 服务后，snapshot.state.inputs 若为对象，消息被原样缓存并触发按钮重画；tally.js 对它调用 .find() 抛出未处理 TypeError。

#### Root Cause

客户端只按 JSON type 分类快照，不校验 state.inputs/outputs 的数组形状；按钮样式代码假设数组并直接调用 find/filter，事件回调没有捕获同步异常。

**网络快照未经结构校验** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:103`

任意 JSON 类型的 state.inputs 被存入快照并由下一行同步发出事件。

```javascript
this.snapshot = message;
```

**假定 inputs 是数组** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/tally.js:33`

攻击者提供对象时同步抛出 TypeError，中断未捕获的重画回调。

```javascript
const found = inputs.find((i) => i.number === input);
```

#### Validation

`{"type":"snapshot","state":{"inputs":{}}}` 在可见 Preview 按钮时使 Node 退出码1；`inputs:[]` 对照正常。

Validation method: 原始 Node 模块和假 WebSocket 的离线事件链复现

**网络快照未经结构校验** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:103`

任意 JSON 类型的 state.inputs 被存入快照并由下一行同步发出事件。

```javascript
this.snapshot = message;
```

**假定 inputs 是数组** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/tally.js:33`

攻击者提供对象时同步抛出 TypeError，中断未捕获的重画回调。

```javascript
const found = inputs.find((i) => i.number === input);
```

Limitations:
- 未安装 Stream Deck SDK/宿主；宿主若全局拦截未捕获异常，实际影响可能小于插件进程退出。
- 第一方 PlusMix 服务正常编码数组。

#### Dataflow

恶意服务器发送结构错误的 snapshot，客户端同步发出 snapshot 事件，paintAll 的 keyStyle 调用 inputs.find 抛异常。

- **Source:** 被插件配置为目标的恶意服务器或可篡改明文 WS 的网络中间人

- **Sink:** Stream Deck WebSocket snapshot 消息

- **Outcome:** 使插件控制按钮失效或插件进程退出

**网络快照未经结构校验** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:103`

任意 JSON 类型的 state.inputs 被存入快照并由下一行同步发出事件。

```javascript
this.snapshot = message;
```

**假定 inputs 是数组** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/tally.js:33`

攻击者提供对象时同步抛出 TypeError，中断未捕获的重画回调。

```javascript
const found = inputs.find((i) => i.number === input);
```

#### Reachability

被插件配置为目标的恶意服务器或可篡改明文 WS 的网络中间人 经 Stream Deck WebSocket snapshot 消息 可 使插件控制按钮失效或插件进程退出

- **Attacker:** 被插件配置为目标的恶意服务器或可篡改明文 WS 的网络中间人

- **Entry point:** Stream Deck WebSocket snapshot 消息

- **Outcome:** 使插件控制按钮失效或插件进程退出

Preconditions:
- 插件必须连接攻击者可控制/篡改的服务器，连接已建立且存在可见 Preview/Program/Tally 按钮；默认回环配置降低风险。

Limitations:
- 未安装 Stream Deck SDK/宿主；宿主若全局拦截未捕获异常，实际影响可能小于插件进程退出。
- 第一方 PlusMix 服务正常编码数组。

#### Severity

**Low** — 影响限于 Stream Deck 插件按钮可用性，须恶意服务端或远程明文链路篡改，第一方正常快照不会产生该类型。

插件必须连接攻击者可控制/篡改的服务器，连接已建立且存在可见 Preview/Program/Tally 按钮；默认回环配置降低风险。

Impact assessment:
- **Level:** low
- **Why:** 影响限于 Stream Deck 插件按钮可用性，须恶意服务端或远程明文链路篡改，第一方正常快照不会产生该类型。

Likelihood assessment:
- **Level:** low
- **Why:** 插件必须连接攻击者可控制/篡改的服务器，连接已建立且存在可见 Preview/Program/Tally 按钮；默认回环配置降低风险。

#### Remediation

在 SwitcherClient 接受快照前验证 state.inputs/outputs 等结构，重画事件边界捕获异常并丢弃畸形消息。

Tests:
- 畸形 inputs/outputs 的 snapshot 不应抛出到 WebSocket 回调。
- 合法快照仍正常重画按钮。

<a id="finding-11"></a>

### [11] 新发现：Stream Deck 插件把 API token 写入日志

| Field | Value |
| --- | --- |
| Severity | low |
| Confidence | high |
| Confidence rationale | 实际 URL 构造与日志语句直接相连，离线 Node 模块输出带测试 token。 |
| Category | Insertion of sensitive information into log file |
| CWE | CWE-532 |
| Affected lines | Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/bin/plugin.js:66-72, Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:28-30, Packages/SwitcherControl/Sources/SwitcherControl/API/APIServer.swift:256 |

#### Summary

插件把全局设置 token 加到 WebSocket URL 查询串，成功连接后将 client.url 原样写入 info 日志；日志读取者可取得并重放 token。

#### Root Cause

插件复用含凭据的连接 URL 做用户可见连接日志，而没有先剥离查询串。

**令牌在 URL 查询串** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:29`

设置中的 token 加到 client.url。

```javascript
const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
```

**完整 URL 写入 info 日志** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/bin/plugin.js:72`

连接成功事件将带 token 的 client.url 原样写入日志。

```javascript
client.on("connected", () => { streamDeck.logger.info(`已连上 ${client.url}`); paintAll(); });
```

#### Validation

测试 token 在 client.url 中显示为 ?token=...；connected 回调直接记录该 URL。

Validation method: 静态追踪加离线 Node URL 构造

**令牌在 URL 查询串** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:29`

设置中的 token 加到 client.url。

```javascript
const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
```

**完整 URL 写入 info 日志** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/bin/plugin.js:72`

连接成功事件将带 token 的 client.url 原样写入日志。

```javascript
client.on("connected", () => { streamDeck.logger.info(`已连上 ${client.url}`); paintAll(); });
```

Limitations:
- 未读取真实 Stream Deck 日志；日志接收范围依部署而定。

#### Dataflow

用户配置 token 并连接成功，插件持久日志记录完整 URL，日志读者可重放 token。

- **Source:** 能读取或获得插件日志的人

- **Sink:** Stream Deck 插件 info 日志

- **Outcome:** 取得控制 API token

**令牌在 URL 查询串** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/lib/api-client.js:29`

设置中的 token 加到 client.url。

```javascript
const q = this.token ? `?token=${encodeURIComponent(this.token)}` : "";
```

**完整 URL 写入 info 日志** — `Tools/streamdeck-plugin/com.plusmix.switcher.sdPlugin/bin/plugin.js:72`

连接成功事件将带 token 的 client.url 原样写入日志。

```javascript
client.on("connected", () => { streamDeck.logger.info(`已连上 ${client.url}`); paintAll(); });
```

#### Reachability

能读取或获得插件日志的人 经 Stream Deck 插件 info 日志，取得控制 API token

- **Attacker:** 能读取或获得插件日志的人

- **Entry point:** Stream Deck 插件 info 日志

- **Outcome:** 取得控制 API token

Preconditions:
- 只有在配置 token 且日志被其他人读取或分享时有信息泄露；默认 token 为空。

Limitations:
- 未读取真实 Stream Deck 日志；日志接收范围依部署而定。

#### Severity

**Low** — 令牌泄漏依赖非空 token、成功连接及日志接收者，但令牌可授权控制 API。

只有在配置 token 且日志被其他人读取或分享时有信息泄露；默认 token 为空。

Impact assessment:
- **Level:** low
- **Why:** 令牌泄漏依赖非空 token、成功连接及日志接收者，但令牌可授权控制 API。

Likelihood assessment:
- **Level:** medium
- **Why:** 只有在配置 token 且日志被其他人读取或分享时有信息泄露；默认 token 为空。

#### Remediation

记录主机与端口时去掉 URL 查询串；连接错误日志统一进行凭据脱敏。

Tests:
- 配置虚构 token 后所有日志均不得包含 token 或 token= 查询项。

<a id="finding-12"></a>

### [12] 新发现：编码后的敏感查询参数名绕过推流地址脱敏

| Field | Value |
| --- | --- |
| Severity | low |
| Confidence | high |
| Confidence rationale | 独立 agent 用生产 Swift 脱敏及 ShowRedaction 源码离线复现，诊断 ZIP 写入链静态确认；未运行完整导出 UI。 |
| Category | Sensitive data exposure through improper canonicalization |
| CWE | CWE-180 |
| Affected lines | Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:60-65, App/Sources/Release/ShowRedaction.swift:25-30, App/Sources/Release/DiagnosticBundle.swift:173 |

#### Summary

推流 URL 使用 pa%73s=demo-secret 时，Foundation 会把参数名解码为 pass，但 StreamURLRedaction 按原始字符串匹配，诊断 show's url 仍含原始密码。

#### Root Cause

脱敏函数对原始查询参数名小写后直接与密钥名单比较；下游 URL 解析按百分号解码，导致同一个语义为 pass 的名称在脱敏处不相等，诊断包保留值。

**按原始名称匹配** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:63`

编码后的 pa%73s 不会与敏感名单中的 pass 相等，下一行保留原值。

```swift
let name = String(parts[0])
```

**敏感名单判断** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:64`

只执行 lowercased 而未对参数名做 percent 解码。

```swift
return secretQueryParams.contains(name.lowercased()) ? "\(name)=\(marker)" : String(item)
```

#### Validation

`...?user=alice&pa%73s=demo-secret` 输出仍有 `pa%73s=demo-secret`，而 Foundation queryItems 名称为 pass；ShowRedaction JSON 也保留该值。

Validation method: 使用原始 Swift 脱敏函数与 ShowRedaction 的离线复现

**按原始名称匹配** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:63`

编码后的 pa%73s 不会与敏感名单中的 pass 相等，下一行保留原值。

```swift
let name = String(parts[0])
```

**敏感名单判断** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:64`

只执行 lowercased 而未对参数名做 percent 解码。

```swift
return secretQueryParams.contains(name.lowercased()) ? "\(name)=\(marker)" : String(item)
```

Limitations:
- 未运行 App UI 或最终 ZIP 操作；后续写入代码可达。

#### Dataflow

用户配置编码参数名的 RTMP URL，诊断导出应用有缺陷的脱敏函数，分享后接收者读到密码。

- **Source:** 取得导出诊断包的人

- **Sink:** ShowRedaction 与诊断 ZIP 的 show.switcher.json

- **Outcome:** 获取编码查询参数中的推流密码

**按原始名称匹配** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:63`

编码后的 pa%73s 不会与敏感名单中的 pass 相等，下一行保留原值。

```swift
let name = String(parts[0])
```

**敏感名单判断** — `Packages/SwitcherOutputs/Sources/Streaming/StreamURLRedaction.swift:64`

只执行 lowercased 而未对参数名做 percent 解码。

```swift
return secretQueryParams.contains(name.lowercased()) ? "\(name)=\(marker)" : String(item)
```

#### Reachability

取得导出诊断包的人 经 ShowRedaction 与诊断 ZIP 的 show.switcher.json 可 获取编码查询参数中的推流密码

- **Attacker:** 取得导出诊断包的人

- **Entry point:** ShowRedaction 与诊断 ZIP 的 show.switcher.json

- **Outcome:** 获取编码查询参数中的推流密码

Preconditions:
- 需在原始地址框、节目导入等入口使用编码参数名并导出/分享诊断包；鉴权面板自身不允许 %，不会产生该输入。

Limitations:
- 未运行 App UI 或最终 ZIP 操作；后续写入代码可达。

#### Severity

**Low** — 需要用户配置这种编码写法并分享诊断包；泄漏可使接收者取得推流密码。

需在原始地址框、节目导入等入口使用编码参数名并导出/分享诊断包；鉴权面板自身不允许 %，不会产生该输入。

Impact assessment:
- **Level:** low
- **Why:** 需要用户配置这种编码写法并分享诊断包；泄漏可使接收者取得推流密码。

Likelihood assessment:
- **Level:** low
- **Why:** 需在原始地址框、节目导入等入口使用编码参数名并导出/分享诊断包；鉴权面板自身不允许 %，不会产生该输入。

#### Remediation

对查询参数名按 URL 语义解码后再进行不区分大小写的敏感名匹配，同时保留原始 URL 文字用于非敏感参数。

Tests:
- 对 pass/pa%73s/%70ass 等等价名字断言脱敏结果不含测试密码。
- 诊断 show JSON 和设置页展示均覆盖编码名称。

## Reviewed Surfaces

| Surface | Risk Area | Outcome | Notes |
| --- | --- | --- | --- |
| HTTP/WebSocket 控制 API | Origin、鉴权、命令与敏感状态 | Reported | 默认回环服务的异源 WebSocket、状态凭据与极值命令已静态追踪并以本机生产控制组件验证关键路径；C01/C07/C12。 |
| vMix 兼容 HTTP/TCP | 跨来源命令与资源耗尽 | Reported | 可选 HTTP GET 命令及 TCP 无界行缓存已由独立复核与本机网络探针验证；输入编号极值归入已知；C02/C03/C11。 |
| Tally HTTP/WebSocket | 只读状态暴露 | No issue found | 可选 tally 为只读发布；检查了状态路径和网络回调，未找到可提交命令的入口。 |
| RTMP/RTMPS/SRT/NDI 客户端解析 | 恶意服务端消息和媒体输入 | Reported | 带凭据 RTMP 的 AMF 深嵌套经真实本机握手复现 SIGBUS；推流地址明文与脱敏路径已检查；C05/C06/C08/C09。 |
| Stream Deck 插件连接与日志 | 控制 API token 泄露 | Reported | 检查 WebSocket URL、连接日志和快照事件链；token 日志与畸形快照路径已独立验证；C04/C10。 |
| 推流 URL 凭据与诊断导出 | 凭据通过控制状态、路径和编码查询参数传播 | Reported | 对应 C07/C08/C09；检查 ShowRedaction、DiagnosticBundle 与 URL redaction。 |
