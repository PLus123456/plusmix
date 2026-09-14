import SwitcherContracts

/// 编码线程调用的后端。生产实现是 `VTCompressionBackend`；测试用可控节流的后端证明 E1 的计数精确。
///
/// 线程规则：`encode` 只在 VideoEncoder 的编码线程上被调，允许阻塞（VT 饱和时 EncodeFrame 会背压）；
/// 输出回调可能在任意线程（VT 自己的线程）。
public protocol VideoEncoderBackend: AnyObject {
    /// 建会话。`output` 每编出一帧调一次；`dropped` 每被编码器自己丢一帧调一次。
    func prepare(output: @escaping @Sendable (EncodedVideoSample) -> Void,
                 dropped: @escaping @Sendable () -> Void) throws
    /// 编一帧。`forceKeyframe` 要求这帧是关键帧。
    func encode(_ frame: RenderedFrame, forceKeyframe: Bool) throws
    /// 等所有在途帧的回调都回来。
    func flush()
    /// 释放会话；之后不再有回调。
    func invalidate()
}
