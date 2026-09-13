/* config.h —— libsamplerate 0.2.2 在本仓库（Apple Silicon / macOS）的固定配置。
 * 上游用 CMake / autoconf 生成这个文件；我们不跑它们的构建系统，手写一份等价的。
 * 只启用 sinc 三档转换器（linear / zoh 总是编译）。不改上游任何源文件（THIRD_PARTY/libsamplerate）。 */
#ifndef SW_LIBSAMPLERATE_CONFIG_H
#define SW_LIBSAMPLERATE_CONFIG_H

#define PACKAGE "libsamplerate"
#define VERSION "0.2.2"

#define CPU_CLIPS_NEGATIVE 0
#define CPU_CLIPS_POSITIVE 0
#define CPU_IS_BIG_ENDIAN 0
#define CPU_IS_LITTLE_ENDIAN 1

#define HAVE_LRINT 1
#define HAVE_LRINTF 1
#define HAVE_STDBOOL_H 1
#define HAVE_STDINT_H 1
#define HAVE_UNISTD_H 1

#define ENABLE_SINC_FAST_CONVERTER 1
#define ENABLE_SINC_MEDIUM_CONVERTER 1
#define ENABLE_SINC_BEST_CONVERTER 1

#define SIZEOF_INT 4
#define SIZEOF_LONG 8

#endif
