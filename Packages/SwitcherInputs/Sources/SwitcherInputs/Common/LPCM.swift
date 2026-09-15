import AudioToolbox
import CoreMedia

/// LPCM 样本格式转换：CMSampleBuffer（float32 / int16 / int24 / int32，交错或非交错，任意声道）→ float32 非交错平面。
/// 声道映射：源声道数 ≥ 目标取前几路；源单声道复制到所有声道；源少于目标时缺的复制最后一路。
enum LPCM {
    /// 把 sampleBuffer 的样本追加到 `planes`（长度 = 目标声道数）。返回帧数；不是 LPCM 返回 0。
    static func append(sampleBuffer: CMSampleBuffer, to planes: inout [[Float]]) -> Int {
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return 0 }
        let asbd = asbdPtr.pointee
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame > 0, frames > 0, !planes.isEmpty else { return 0 }
        var listSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: &listSize,
                                                                              bufferListOut: nil, bufferListSize: 0,
                                                                              blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                              flags: 0, blockBufferOut: nil)
        guard status == noErr || status == kCMSampleBufferError_ArrayTooSmall, listSize > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, bufferListSizeNeededOut: nil,
                                                                          bufferListOut: abl, bufferListSize: listSize,
                                                                          blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                          flags: 0, blockBufferOut: &block)
        guard status == noErr else { return 0 }
        defer { _ = block }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bits = Int(asbd.mBitsPerChannel)
        let srcChannels = Int(asbd.mChannelsPerFrame)
        func source(channel c: Int) -> (UnsafeRawPointer, Int)? {
            if nonInterleaved {
                guard c < buffers.count, let d = buffers[c].mData else { return nil }
                return (UnsafeRawPointer(d), bits / 8)
            }
            guard let d = buffers[0].mData, c < srcChannels else { return nil }
            return (UnsafeRawPointer(d) + c * (bits / 8), srcChannels * (bits / 8))
        }
        for c in 0..<planes.count {
            let sc = srcChannels == 1 ? 0 : min(c, srcChannels - 1)
            planes[c].reserveCapacity(planes[c].count + frames)
            guard let (base, stride) = source(channel: sc) else {
                planes[c].append(contentsOf: repeatElement(0, count: frames))
                continue
            }
            if isFloat && bits == 32 {
                for i in 0..<frames { planes[c].append((base + i * stride).loadUnaligned(as: Float.self)) }
            } else if !isFloat && bits == 16 {
                for i in 0..<frames { planes[c].append(Float((base + i * stride).loadUnaligned(as: Int16.self)) / 32768) }
            } else if !isFloat && bits == 32 {
                for i in 0..<frames { planes[c].append(Float((base + i * stride).loadUnaligned(as: Int32.self)) / 2_147_483_648) }
            } else if !isFloat && bits == 24 {
                for i in 0..<frames {
                    let p = (base + i * stride).assumingMemoryBound(to: UInt8.self)
                    let v = Int32(bitPattern: (UInt32(p[2]) << 24) | (UInt32(p[1]) << 16) | (UInt32(p[0]) << 8)) >> 8
                    planes[c].append(Float(v) / 8_388_608)
                }
            } else {
                planes[c].append(contentsOf: repeatElement(0, count: frames))
            }
        }
        return frames
    }
}
