# 图标与 README 演示（2026-11-08）

基线：`1886bde`；分支：`codex/readme-visuals`。工作树：`/Users/plus/.codex/worktrees/f8f1/plusmix`。用户要求先做图标，再把实际功能演示放进 README；补充要求接入 macOS 应用图标，并在无冲突时同步回 `/Users/plus/plusmix`。用户于 2026-11-08 确认最终图标并要求提交；按仓库约定在本分支提交，不推送、不合并或发布。

## 1. 做了什么

- 图标：深色底、预览绿 / 播出红双画面、白色加号。用户在 2026-11-08 复核后要求两块画面的外圈一致、加号离开中间，并指定用 image2 调整；已用内置 image_gen 生成修订方案，再整理成可编辑 SVG：两块面板共用同一组 10 单位深色描边和 34 单位圆角，加号收进红色面板右下角。README PNG 与十档 macOS AppIcon 都由同一 SVG 导出。
- 本轮 image2 生成原图与完整提示词保留在 `docs/media/design/`；实际图标的源仍为 SVG，生成参考图不作为 PNG 的隐含依赖。16 px 与 512 px 修订版都已目视检查。
- 新增 `App/Resources/Assets.xcassets/AppIcon.appiconset/`，`project.yml` 只增加 `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`。构建后生成 `AppIcon.icns` 与 `Assets.car`，Info.plist 的 `CFBundleIconName` = `AppIcon`。
- 两段真实 AppKit / Metal 主窗口录屏，各 12 秒：PVW 选择 → Cut → Fade → Wipe；字幕滑入 → 画中画淡入 → 分别收起。来源为原创静态演示图，不伪称摄像头实拍，解说只加在窗口外围。
- README 增加图标、演示说明、两段 GIF、静态图入口、素材维护文档；原有内容完整保留。输出 960×720 / 12 fps / 144 帧循环 GIF，分别 1,155,953 与 978,840 字节，合计 2.04 MiB。
- 图标导出、演示图 / 节目生成、单窗口录制、中文说明与 GIF 编码全部可重跑，入口在 `docs/media/tools/`，说明在 `docs/media/README.md`。原始录屏、运行证据和临时素材仅在 `.build/readme-media/`。
- `docs/OWNERSHIP.md` 登记本次用户直接授权的文件范围；不改核心包、应用运行逻辑或公共契约。

## 2. 验证

| 检查 | 结果 / 判定 |
|---|---|
| Debug App 构建（当前源码 + 最终 AppIcon） | 通过。XcodeGen + xcodebuild，`CODE_SIGNING_ALLOWED=NO`；使用已有且版本锁定的依赖副本，首轮 `build-icons.log`、image2 修订轮 `build-icon-v2.log` 均无错误。既有 NDI 重复 rpath 警告不影响本次构建 |
| 图标资源 | 10 张 PNG 尺寸与 `Contents.json` 的 16/32/128/256/512 pt × 1/2 倍全部匹配；均有 alpha；最大 1024 px。SVG XML 可解析；16 px 与 512 px 已目视检查 |
| 实机演示状态 | 10 个检查点通过：PGM/PVW 编号、转场已结束、叠加 on 与 animProgress 到达对应端点。每条演示命令回执 applied = true（初始化幂等命令除外） |
| 演示运行统计 | 最后采样四路图片输入各 30.06 fps，render_ms = 0.956，missed_render = 0。仅为本次短演示记录，不作为性能或长稳验收 |
| GIF | 两段各 960×720、144 帧、12.00 s，含循环扩展，各小于 2 MiB。抽查选择、硬切、淡变中间、擦除中间、字幕、画中画、分别退出与结尾帧，画面与文案一致 |
| README 媒体渲染 | Pandoc GFM 本地预览 + 浏览器检查：图标、两段 GIF 均加载成功；图标显示 112×112，两段动画保持 4:3 比例。仅本地预览，未上传 GitHub |
| 文档与语法 | `git diff --check`、相对链接检查、Python 编译检查、两份 Swift 工具 typecheck 通过 |
| 仓库 lint | `make lint` 提交前复跑全部通过：版本 / 禁词 / 包约束、8 包依赖方向、归属、随包手册、228 份 Markdown、音频热路径符号。归属脚本默认仅查已提交内容；本次 30 个待提交文件另按登记范围核对，既有未跟踪 `vmix-28-guide.zip` 不属于本次且保持原样 |

原始证据目录（只在本次工作树）：`/Users/plus/.codex/worktrees/f8f1/plusmix/.build/readme-media/`，含 `build-icons.log`、`build-icon-v2.log`、`lint.log`、`commit-lint.log`、`capture-log.json`、`capture-stats.jsonl`、两份原始 MOV、抽帧拼图。

## 3. 没做的和原因

- 没有全量重跑业务单元测试 / 长稳 / 硬件测试：改动仅媒体、文档和 AppIcon 构建设置；已完成构建与真实运行验证。
- 没有签名、公证或发布；演示不涉及真实采集设备、外网推流、音频混音、NDI 等设备能力，GIF 本身无音频。
- 首轮原项目同步包含 28 个相关文件；本轮再增加 image2 参考图和提示词，并更新图标资源及说明。每轮同步前核对原目录是否有并发修改，新增目标不覆盖已有文件；同步后逐文件校验 SHA-256。不拷贝构建缓存、原始录屏或用户已有未跟踪资料。

## 4. 对契约的疑问

无。本次只调用既有命令和节目格式，没有契约变更。

## 5. 下一个会话需要知道的坑

- macOS 窗口被遮挡时 `MetalDisplayView` 会暂停呈现。第一轮叠加录屏因此出现 UI 状态正确而监视器画面滞留；重新置前录制后正常，未认定为引擎缺陷、未改业务逻辑。最终录制工具禁止自身抢前台，等待 PlusMix 激活，并在录制中检查前台；失焦直接失败，避免产出误导素材。录制期间不要切换到其他应用。
- 屏幕录制权限必须已有；脚本只录它自己启动的 PlusMix 主窗口。使用测试宿主模式隔离配置，录制结束只关闭本次子进程。
- 资源在 `docs/media/` 使用相对链接，原始 MOV 被 `.gitignore` 排除。不要把演示窗口的时钟、短时统计或原创图片标签解释为产品基准、真实现场或设备兼容承诺。
- 当前主程序图标由 asset catalog 提供；修改图标先改 SVG，再运行 `make-icons.py`，不要手改某一张 PNG。原项目需重新构建后才会在新 App 中使用图标。
