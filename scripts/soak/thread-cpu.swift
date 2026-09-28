// 每线程 CPU 时间快照（S3 归因用）：proc_pidinfo 走 proc_info，不要 task port、不要 sudo、不碰 DevToolsSecurity；只能看自己用户的进程。
// 用法：thread-cpu <pid>
// 输出：第一行 "# ts=<epoch> pid=<pid> threads=<n>"，之后每线程一行：tid<TAB>user_us<TAB>system_us<TAB>name<TAB>pri=<当前优先级><TAB>policy=<调度策略>
// （无名线程 name 为空；pri / policy 给"线程落在哪类核上"的探查用：默认 31、用户交互 37、后台 4、实时 > 80；policy 1 = 分时、2 = 实时、4 = 固定优先级）。
// soak.sh 每分钟追加一份到 threads.log；soak_report.py 用首尾两份的差算每个线程占一个核的百分比（同 Stats.cpu_pct 的口径：100 = 一个核）。
// 编译：swiftc -O -o .build/soak/thread-cpu scripts/soak/thread-cpu.swift（soak.sh 自己做）。
import Darwin
import Foundation

guard CommandLine.arguments.count >= 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("用法：thread-cpu <pid>\n".data(using: .utf8)!)
    exit(2)
}
let maxThreads = 4096
var tids = [UInt64](repeating: 0, count: maxThreads)
let bytes = proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, &tids, Int32(MemoryLayout<UInt64>.size * maxThreads))
guard bytes > 0 else {
    FileHandle.standardError.write("proc_pidinfo(PROC_PIDLISTTHREADS) 失败：errno \(errno)（\(String(cString: strerror(errno)))）\n".data(using: .utf8)!)
    exit(1)
}
let count = Int(bytes) / MemoryLayout<UInt64>.size
var lines: [String] = []
for i in 0..<count {
    var info = proc_threadinfo()
    let r = proc_pidinfo(pid, PROC_PIDTHREADINFO, tids[i], &info, Int32(MemoryLayout<proc_threadinfo>.size))
    guard r > 0 else { continue }   // 线程刚退出：跳过
    let name = withUnsafeBytes(of: &info.pth_name) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
    lines.append("\(tids[i])\t\(info.pth_user_time / 1000)\t\(info.pth_system_time / 1000)\t\(name)\tpri=\(info.pth_curpri)\tpolicy=\(info.pth_policy)")
}
print("# ts=\(Int(Date().timeIntervalSince1970)) pid=\(pid) threads=\(lines.count)")
print(lines.joined(separator: "\n"))
