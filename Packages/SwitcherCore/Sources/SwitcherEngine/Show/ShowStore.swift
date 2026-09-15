import Foundation
import SwitcherContracts

// 节目文件读写 + schemaVersion 逐级迁移框架（设计方案 §4："带 schemaVersion，老版本要能读"）。
// 契约里 Show.load / Show.migrate 只认当前版本；这里在它前面加一层：读 schemaVersion → 按注册的迁移步
// （k → k+1）逐级把 JSON 文档升到当前版本 → 交给 Show.migrate 解码并校验。
// 现在只有 v1，没有真实迁移；测试用一步假迁移证明框架能跑。将来出 v2 时在这里注册 v1 → v2 的步骤。

/// 一步迁移：把 fromVersion 的文档变成 fromVersion + 1 的文档（要自己把 schemaVersion 字段改掉）。
public struct ShowMigration: Sendable {
    public let fromVersion: Int
    public let apply: @Sendable (JSONValue) throws -> JSONValue
    public init(fromVersion: Int, apply: @escaping @Sendable (JSONValue) throws -> JSONValue) {
        self.fromVersion = fromVersion
        self.apply = apply
    }
}

/// 节目文件存取。
public final class ShowStore: Sendable {
    private let migrations: [Int: ShowMigration]

    public init(migrations: [ShowMigration] = []) {
        var table: [Int: ShowMigration] = [:]
        for m in migrations { table[m.fromVersion] = m }
        self.migrations = table
    }

    /// 从 version 升到当前版本要走的步骤（各步的 fromVersion）；缺环返回 nil；已是当前版本返回 []。
    public func migrationPath(from version: Int) -> [Int]? {
        guard version <= Show.currentSchemaVersion else { return nil }
        var path: [Int] = []
        var v = version
        while v < Show.currentSchemaVersion {
            guard migrations[v] != nil else { return nil }
            path.append(v)
            v += 1
        }
        return path
    }

    /// 读文件。
    public func load(from url: URL) throws -> Show {
        try load(data: try Data(contentsOf: url))
    }

    /// 解析文件内容：当前版本直接解；旧版本逐级迁移；缺 schemaVersion / 未知版本 / 缺环抛错。
    public func load(data: Data) throws -> Show {
        struct Header: Decodable { let schemaVersion: Int? }
        let header: Header
        do { header = try Show.fileDecoder.decode(Header.self, from: data) } catch { throw ShowError.malformed("不是 JSON 对象：\(error)") }
        guard let version = header.schemaVersion else { throw ShowError.malformed("缺少 schemaVersion") }
        if version == Show.currentSchemaVersion { return try Show.load(from: data) }
        guard let path = migrationPath(from: version) else { throw ShowError.unsupportedSchemaVersion(version) }
        var document = try Show.fileDecoder.decode(JSONValue.self, from: data)
        for step in path {
            document = try migrations[step]!.apply(document)
        }
        return try Show.migrate(from: document, schemaVersion: Show.currentSchemaVersion)
    }

    /// 原子写文件（先写临时文件再换名）。
    public func save(_ show: Show, to url: URL) throws {
        let data = try show.save()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
