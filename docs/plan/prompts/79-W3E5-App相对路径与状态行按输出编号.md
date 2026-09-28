## 79 W3-E5 App：素材相对路径相对节目文件；状态行按输出编号对号（用户 2026-09-28 指派 agent 直接做）
分支：w3-app-6（从 W4-D 改名合入后的 main 开）。只准动：App/、Samples/README.md（只删"App 修好前的临时办法"一段）。
先读：reports/issues/W4C-app-relative-media-paths.md（改法与用例都写好了）、reports/w3-app-5.md §3 第 2 条 / §5 第 3 条、Tools/switcher-headless 里相对路径的解析（只读，照同一条规则）。

交付（每条一个用例）：
1. 图片 / 视频文件输入的非绝对路径按**节目文件所在目录**解析（与 headless 同一规则），节目没保存过时退到 ~/Movies/Switcher；只改交给输入对象的路径，MixerState / 节目文件仍存相对路径。用例：节目在临时目录 A、图片在 A/assets/，进程 cwd 在别处，打开后该路 live、fps > 0。修完删 Samples/README.md 里的临时办法段。
2. 底栏状态行的"编码跳帧 / 码率"按 `Stats.encoder[].output` 查 `state.outputs` 的 kind 对号（不再按顺序），`StatusLineFormatter.activeEncoder` 的参数改成 `[Int: OutputKind]` 之类；用例：一行顺序颠倒的 Stats 也能显示对的类型。
3. W2-C2 把 `UserConfig.directory` 改成 `~/Library/Application Support/PlusMix` 之后，App 里写死旧目录 / 旧名字的地方（LastSession 等）跟改；FaceTime 设备名等包内常量已由检查点改。
4. `make test-app` 全量在空机器上跑（先 `pgrep -fl "xcodebuild .*test"`），0 失败；`make lint BRANCH=w3-app-6`。
不做：包与契约。报告 reports/w3-app-6.md。不 push、不 merge。
