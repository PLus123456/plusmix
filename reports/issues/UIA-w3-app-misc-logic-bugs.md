# App 里几处小的逻辑缺陷（外部输出菜单的勾、输入上限、提示文字、转场类型被悄悄改）

归属会话 / 分支：App 会话（W3-E 系）；第 2 条的校验放在控制层（W2-C 系，`Packages/SwitcherControl/.../CommandValidator.swift`）或 reducer（W1-B 系），由检查点定
发现于：界面对照调研 UIA，提交 c836cce；R2-M09 / G24、R3a-M08 / M09、VF1 §4 第 7、9 条
现象：
1. 外部输出菜单的勾只看"这对（显示器, 源）的输出存不存在"，不看开没开：在输出设置里关掉某一路以后菜单仍打勾，再点一次删掉的是整条配置，不是把它打开（`App/Sources/UI/ExternalOutputMenu.swift:65`、`:106-107`）。
2. API / 快捷键 / 节目文件能加超出引擎容量的输入（例如 17 号，容量 16）：格子会出现，但运行表只打一行日志、不接这一路，格子上没有任何提示（`CommandValidator.swift:43-46`；`MixerReducer.swift:207-212`；`App/Sources/Engine/InputRuntime.swift:55-58`）。添加面板在 16 个号用满后编号下拉为空、仍能点"添加"，命令被拒只在底栏提示一句（`App/Sources/UI/AddInputSheet.swift:225-228`、`:756-760`）。
3. Fade 按钮的提示写死"回车"，但默认表里回车是"按当前选中的转场"（选过 Wipe 之后回车走的是 Wipe）；改了快捷键表提示也不跟（`App/Sources/UI/TransitionPanelView.swift:77-79`；`Packages/SwitcherControl/Sources/SwitcherControl/Hotkeys/HotkeyTable.swift:66-68`）。
4. 点 Fade 按钮或菜单"切换 › Fade"会把"下一次转场"改成 Fade，T-bar 和回车随之变成 Fade，界面不提示（`MixerReducer.swift:81-85`）。
5. 转场列 Overlay 1–4 在通道没指定输入时按下去：通道记为开、按钮变蓝，但没有画面（`TransitionPanelView.swift:194-198`）。
6. 窗口菜单"调音台 / 多画面"是开关，但没有 ✓（`App/Sources/AppDelegate.swift:148-149`）。
严重级：S3
建议改法：1 勾按 enabled 打、点击改成开关（setOutputEnabled），删除单独一项；2 容量内校验放到命令入口，添加面板满了把"添加"置灰并写明"本节目输入已满（16 路）"，上限本身见 04-待拍板 Q32；3 提示按当前快捷键表反查生成；4、5 随转场列改版（01a-改动总表 C 区）解决，改版前至少让 T-bar 上方那行字在类型被改时有明显变化、空通道按下时用 PVW 那一路；6 按可见性设 state。
