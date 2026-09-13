// sw_rt_attr.h —— 热路径的编译期标注（设计方案 §3.5，测试标准 §2.9）。
//
// Apple clang 21（Xcode 26.6）不支持 -fsanitize=realtime（"unsupported option for target arm64-apple-darwin"，
// W1-D 探针实测），但支持 [[clang::nonblocking]] 与 -Wfunction-effects：
// 标了 SW_NONBLOCKING 的函数在编译期不许调用未标注的函数（malloc、锁、日志、任何外部符号），
// 违者报 -Wfunction-effects；本 target 每个 .c 文件顶部把它升级成错误（sw_rt_pragma.h）。
// 经过审计的第三方 / 系统函数（libsamplerate、libebur128、AudioUnitRender、mach_absolute_time）
// 通过 sw_rt_extern.h 里的显式函数指针转换进入，每一处都写明审计结论。
// 运行期兜底：sw_rt_guard（进入 / 退出标志）+ 测试里挂 malloc_logger 钩子，见 sw_rt_guard.h。
#ifndef SW_RT_ATTR_H
#define SW_RT_ATTR_H

#if defined(__has_c_attribute)
#  if __has_c_attribute(clang::nonblocking)
#    define SW_NONBLOCKING [[clang::nonblocking]]
#    define SW_HAS_NONBLOCKING 1
#  endif
#endif
#ifndef SW_NONBLOCKING
#  define SW_NONBLOCKING
#  define SW_HAS_NONBLOCKING 0
#endif

#endif /* SW_RT_ATTR_H */
