/// 产品版本号。只有这一处和 project.yml 的 `MARKETING_VERSION` 两个地方写版本，
/// `scripts/lint-rules.sh` 校验两者一致；改版本号的会话见 docs/OWNERSHIP.md（G5）。
public enum SwitcherVersion {
    /// 语义化版本字符串，例如 "0.1.0"。
    public static let current = "0.1.0"
}
