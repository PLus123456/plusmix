import SwitcherContracts

/// 推流地址脱敏搬进了 SwitcherContracts（提案 035 第 ① 步，P5-8）：日志、错误文字、诊断包（App 的 ShowRedaction）、地址框、API 对外状态（137 落地后）共用契约里那一份口径。
/// 这里只留别名，推流包与 App 原来的调用点（`StreamURLRedaction.redact(url:)` / `.redact(text:)` / `.marker` / `.secretQueryParams`）一行不改。
public typealias StreamURLRedaction = SwitcherContracts.StreamURLRedaction
