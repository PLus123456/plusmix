# libebur128 1.2.6

- 来源：https://github.com/jiixyj/libebur128/archive/refs/tags/v1.2.6.tar.gz
- SHA-256（tar.gz）：baa7fc293a3d4651e244d8022ad03ab797ca3c2ad8442c43199afe8059faa613
- 拷贝的文件：ebur128/ebur128.h、ebur128/ebur128.c（上游自带的 queue/sys/queue.h 是给没有 BSD sys/queue.h 的平台用的，macOS SDK 自带，没拷）
- 上游源文件未改动。arm64 上会有一条 `#warning "manual FTZ is being used"`（上游写给 x86 SSE2 的提示，无功能影响）。
- 用途：总线的 EBU R128 M / S / I / LRA 与真峰值表（设计方案 §7）。实时线程里只用 EBUR128_MODE_HISTOGRAM（非直方图模式会在回调里 malloc 链表节点）。
