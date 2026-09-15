// NDI SDK 入口头。SwitcherNDISend 自己编译时 Package.swift 传了 -I（NDI_SDK_DIR 可改）；
// 但 clang 模块 'NDI' 也会在别的 target（测试、headless、App）导入 SwitcherNDISend 时重建，那时没有 -I，
// 所以退到默认安装位置的绝对路径。装在别处又要被别的 target 用到的话，改下面这一行。
#if __has_include(<Processing.NDI.Lib.h>)
#include <Processing.NDI.Lib.h>
#else
#include "/Library/NDI SDK for Apple/include/Processing.NDI.Lib.h"
#endif
