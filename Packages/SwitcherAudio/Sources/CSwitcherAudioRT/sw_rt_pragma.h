// sw_rt_pragma.h —— 热路径每个 .c 文件在**所有 #include 之后**include 它：把 -Wfunction-effects 升级成错误。
// 必须放在 include 之后：clang 模块（其他 C target 的头）是在 include 时导入的，导入前改了诊断选项
// 会和预编译模块的选项冲突（"-Werror=function-effects is currently enabled, but was not in the precompiled file"）。
// 不用 Package.swift 的 unsafeFlags（会让依赖本包的包无法解析），用 pragma 在源文件里生效。
#include "sw_rt_attr.h"
#if defined(__clang__) && SW_HAS_NONBLOCKING
#pragma clang diagnostic error "-Wfunction-effects"
#endif
