import Foundation

/// ISO BMFF / QuickTime 容器的最小索引（frameprobe 用）：每条轨的类型、时标、编码、编辑列表，以及分片文件里每条轨**第一个分片的解码起点**（tfdt）。
///
/// 为什么要自己读：AVFoundation 对**没有编辑列表的分片文件**（MediaMTX 落盘的推流 fMP4）把每条轨各自归零——音轨 tfdt = 960（20 ms）、视频 tfdt = 0，
/// `AVAssetTrack.timeRange.start` 与解码输出第一个 PTS 都报 0（W1-A2 探针：把两条轨的 tfdt 各加 1 s 后 AVFoundation 仍报 0 / 0，ffprobe 报 1.000 / 1.020），
/// 音轨相对视频的起始偏移就丢了；同时它对 AAC 按 2112 样本裁 priming（直通样本带 TrimDurationAtStart = 2112，
/// 是 AVFoundation 自己合成的：容器里没有 elst），裁了却没把时间轴往后挪。两样加起来就是 W2-D 报的 +64 ms（reports/issues/W2D-w1-testkit-frameprobe-av-on-stream-recordings.md）。
/// 有编辑列表的文件（AVAssetWriter 写的录制文件：elst media_time = 2112）AVFoundation 算得对，不用管。
///
/// 只读 box 头，不读 mdat（GB 级文件也只是几十次 seek）；moov 里只解 trak 的 tkhd / mdhd / hdlr / stsd / edts.elst；
/// moof 只读到每条轨都有了第一个 tfdt 为止。不是 MP4 / MOV（没有 ftyp / moov）返回 nil。
public struct MP4Index: Hashable, Sendable {
    public struct EditListEntry: Hashable, Sendable {
        /// 片段时长（movie 时标）。
        public var segmentDuration: Int64
        /// 媒体起点（轨时标）；−1 = 空片段。
        public var mediaTime: Int64
    }

    public struct Track: Hashable, Sendable {
        public var id: UInt32
        /// hdlr 的 handler_type："vide" / "soun" / …
        public var handler: String
        /// mdhd 时标。
        public var timescale: UInt32
        /// stsd 第一个条目的类型："avc1" / "mp4a" / "lpcm" / …
        public var codec: String
        public var editList: [EditListEntry]
        /// 第一个分片的 tfdt.baseMediaDecodeTime（轨时标）；非分片文件 / 没找到为 nil。
        public var firstFragmentDecodeTime: UInt64?

        public var hasEditList: Bool { !editList.isEmpty }
        /// 第一个分片的解码起点（秒）；非分片为 0。
        public var firstFragmentStartSeconds: Double {
            firstFragmentDecodeTime.map { Double($0) / Double(max(1, timescale)) } ?? 0
        }
    }

    public var tracks: [Track]
    /// 有 moof（分片文件）。
    public var isFragmented: Bool
    /// 文件里 moof 的个数（只数到每条轨都有了第一个 tfdt 为止，之后的不数）。
    public var scannedFragments: Int

    public var videoTrack: Track? { tracks.first { $0.handler == "vide" } }
    public var audioTrack: Track? { tracks.first { $0.handler == "soun" } }

    /// 音轨第一个样本相对视频轨第一个样本的时刻（秒）：分片文件里 = tfdt 之差（AVFoundation 把两条轨各自归零后丢掉的量）；
    /// 非分片文件为 0（AVFoundation 按 elst / stts 算得对）。
    public var audioStartRelativeToVideoSeconds: Double {
        guard isFragmented, let a = audioTrack else { return 0 }
        return a.firstFragmentStartSeconds - (videoTrack?.firstFragmentStartSeconds ?? 0)
    }

    // MARK: 读

    public enum IndexError: Error, CustomStringConvertible {
        case cannotOpen(String)
        public var description: String {
            switch self {
            case .cannotOpen(let s): "打不开：\(s)"
            }
        }
    }

    /// 读文件的索引；不是 MP4 / MOV 返回 nil。
    public static func scan(url: URL, maxFragments: Int = 4096) throws -> MP4Index? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { throw IndexError.cannotOpen(url.path) }
        defer { try? handle.close() }
        let reader = Reader(handle: handle)
        let end = reader.length
        var tracks: [Track] = []
        var sawFtyp = false, sawMoov = false
        var fragments = 0
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard let box = reader.box(at: offset) else { break }
            switch box.type {
            case "ftyp":
                sawFtyp = true
            case "moov":
                sawMoov = true
                tracks = parseMoov(reader, box)
            case "moof":
                fragments += 1
                for (trackID, decodeTime) in parseMoof(reader, box) {
                    if let i = tracks.firstIndex(where: { $0.id == trackID }), tracks[i].firstFragmentDecodeTime == nil {
                        tracks[i].firstFragmentDecodeTime = decodeTime
                    }
                }
                if !tracks.isEmpty && tracks.allSatisfy({ $0.firstFragmentDecodeTime != nil }) || fragments >= maxFragments {
                    return MP4Index(tracks: tracks, isFragmented: true, scannedFragments: fragments)
                }
            default:
                break
            }
            guard box.size >= 8 else { break }
            offset += box.size
        }
        guard sawFtyp || sawMoov else { return nil }
        return MP4Index(tracks: tracks, isFragmented: fragments > 0, scannedFragments: fragments)
    }

    // MARK: - 解析

    struct Box {
        var type: String
        var offset: UInt64
        var size: UInt64
        var headerSize: UInt64
        var payloadOffset: UInt64 { offset + headerSize }
        var end: UInt64 { offset + size }
    }

    final class Reader {
        let handle: FileHandle
        let length: UInt64
        init(handle: FileHandle) {
            self.handle = handle
            length = (try? handle.seekToEnd()) ?? 0
        }
        func bytes(at offset: UInt64, count: Int) -> Data? {
            guard offset + UInt64(count) <= length, (try? handle.seek(toOffset: offset)) != nil else { return nil }
            guard let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        func box(at offset: UInt64) -> Box? {
            guard let h = bytes(at: offset, count: 8) else { return nil }
            var size = UInt64(h.u32(0))
            let type = h.fourCC(4)
            var header: UInt64 = 8
            if size == 1 {
                guard let l = bytes(at: offset + 8, count: 8) else { return nil }
                size = l.u64(0)
                header = 16
            } else if size == 0 {
                size = length - offset
            }
            guard size >= header else { return nil }
            return Box(type: type, offset: offset, size: size, headerSize: header)
        }
        /// 直接子 box。
        func children(of parent: Box) -> [Box] {
            var out: [Box] = []
            var o = parent.payloadOffset
            while o + 8 <= parent.end {
                guard let b = box(at: o), b.size >= 8 else { break }
                out.append(b)
                o += b.size
            }
            return out
        }
        func child(_ parent: Box, _ path: [String]) -> Box? {
            var cur = parent
            for name in path {
                guard let next = children(of: cur).first(where: { $0.type == name }) else { return nil }
                cur = next
            }
            return cur
        }
    }

    static func parseMoov(_ r: Reader, _ moov: Box) -> [Track] {
        var tracks: [Track] = []
        for trak in r.children(of: moov) where trak.type == "trak" {
            guard let tkhd = r.child(trak, ["tkhd"]), let tkhdData = r.bytes(at: tkhd.payloadOffset, count: min(Int(tkhd.size - tkhd.headerSize), 32)),
                  let mdia = r.child(trak, ["mdia"]), let mdhd = r.child(mdia, ["mdhd"]), let mdhdData = r.bytes(at: mdhd.payloadOffset, count: min(Int(mdhd.size - mdhd.headerSize), 32)),
                  let hdlr = r.child(mdia, ["hdlr"]), let hdlrData = r.bytes(at: hdlr.payloadOffset, count: 12) else { continue }
            let tkhdVersion = tkhdData[0]
            let id = tkhdVersion == 1 ? tkhdData.u32(20) : tkhdData.u32(12)
            let mdhdVersion = mdhdData[0]
            let timescale = mdhdVersion == 1 ? mdhdData.u32(20) : mdhdData.u32(12)
            let handler = hdlrData.fourCC(8)
            var codec = ""
            if let stsd = r.child(mdia, ["minf", "stbl", "stsd"]), let d = r.bytes(at: stsd.payloadOffset, count: 16) {
                codec = d.fourCC(12)
            }
            var edits: [EditListEntry] = []
            if let elst = r.child(trak, ["edts", "elst"]), let head = r.bytes(at: elst.payloadOffset, count: 8) {
                let version = head[0]
                let n = Int(head.u32(4))
                let entrySize = version == 1 ? 20 : 12
                if let body = r.bytes(at: elst.payloadOffset + 8, count: min(n * entrySize, 64 * entrySize)) {
                    for i in 0..<(body.count / entrySize) {
                        let o = i * entrySize
                        if version == 1 {
                            edits.append(EditListEntry(segmentDuration: Int64(bitPattern: body.u64(o)), mediaTime: Int64(bitPattern: body.u64(o + 8))))
                        } else {
                            edits.append(EditListEntry(segmentDuration: Int64(body.u32(o)), mediaTime: Int64(Int32(bitPattern: body.u32(o + 4)))))
                        }
                    }
                }
            }
            tracks.append(Track(id: id, handler: handler, timescale: timescale, codec: codec, editList: edits, firstFragmentDecodeTime: nil))
        }
        return tracks
    }

    /// 一个 moof 里每个 traf 的 (track_ID, tfdt)。
    static func parseMoof(_ r: Reader, _ moof: Box) -> [(UInt32, UInt64)] {
        var out: [(UInt32, UInt64)] = []
        for traf in r.children(of: moof) where traf.type == "traf" {
            var trackID: UInt32?
            var decodeTime: UInt64?
            for b in r.children(of: traf) {
                if b.type == "tfhd", let d = r.bytes(at: b.payloadOffset, count: 8) { trackID = d.u32(4) }
                if b.type == "tfdt", let d = r.bytes(at: b.payloadOffset, count: 12) {
                    decodeTime = d[0] == 1 ? d.u64(4) : UInt64(d.u32(4))
                }
            }
            if let trackID, let decodeTime { out.append((trackID, decodeTime)) }
        }
        return out
    }
}

private extension Data {
    func u32(_ o: Int) -> UInt32 {
        let i = startIndex + o
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) << 32 | UInt64(u32(o + 4)) }
    func fourCC(_ o: Int) -> String {
        let i = startIndex + o
        return String(decoding: self[i..<(i + 4)], as: UTF8.self)
    }
}
