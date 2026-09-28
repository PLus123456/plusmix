# 来源

- 库：NDI® SDK for Apple（Vizrt NDI AB），运行库 `lib/macOS/libndi.dylib`（universal x86_64 + arm64，minos 13.0，Vizrt 签名）。
- 版本：以打包机 `/Library/NDI SDK for Apple/Version.txt` 为准（W4-B 打包时：见 reports/w4-release.md §1）；NDI_SDK_DIR 环境变量可改目录。
- 获取：https://ndi.video/for-developers/ndi-sdk/ 注册下载安装；不进仓库（大且有许可条款）。
- 用法：scripts/release/archive.sh 在导出后把 libndi.dylib 拷进 `Switcher.app/Contents/Frameworks/`，删掉主二进制里指向 SDK 目录的 LC_RPATH，
  连同 `libndi_licenses.txt` 与 NOTICE.md 放进 `Contents/Resources/Licenses/NDI/`，再用同一身份重签。
- 本目录的 `libndi_licenses.txt` 是 SDK 附带文件的原样副本（SDK 要求随二进制分发），升级 SDK 时替换它。
