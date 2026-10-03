# ImageInput 只在 start() 解码一次、不监视文件：外面改了 PNG 画面不变（App 先用 DispatchSource + 停了再起顶着）

归属会话 / 分支：输入会话（W2-A 系）；`Packages/SwitcherInputs/Sources/SwitcherInputs/Image/ImageInput.swift`
发现于：W5-H（prompt 94，分支 w5-app-input-strip），2026-10-03；01a G14 / 02 X 的"图片改了自动换上"（做字幕 / 台标最常用的路子）
严重级：S3（功能缺口；App 侧已有接线，功能对用户可用，问题在实现位置与细节）

## 现象

`ImageInput.start()` 把文件解码成一个 IOSurface 像素缓冲，拍点线程之后每拍推同一个缓冲（ImageInput.swift:78–102、:119–140）；
文件在外面被改了（编辑器原地保存或"写临时文件再改名盖过去"），输入不知道，画面一直是旧图。
G14 要求"外面改了 PNG 下一拍换上"；prompt 94 定：包里没有监视就由 App 接线，并给 W2-A 系写这张单。

## App 现在怎么做的（W5-H，只动 App/）

- `App/Sources/Engine/ImageFileWatcher.swift`：`DispatchSource.makeFileSystemObjectSource`（O_EVTONLY，事件 write / extend / attrib / delete / rename / link / revoke，主队列）
  盯解析后的绝对路径；delete / rename / revoke = 旧 inode 不再代表这条路径，按路径重开；文件不在时每 0.25 s 看一眼；
  一阵事件合成一次（20 ms）；用 ImageIO 的 `CGImageSourceGetStatus == complete` 挡住写到一半的文件；修改时间 / 大小 / inode 都没变不重读。
- `InputRuntime.reloadImage`：对**同一个** ImageInput 对象 `stop()` 再 `start()`（start 按同一条路径重新解码），帧槽、引擎注册、ISO 分支都不动，
  PGM 停在上一帧、下一拍换上，不闪黑。用例 `InputStripTests.testUI_imageInputReloadsWhenFileChanges`：原子替换约 100 ms、原地覆盖约 70 ms 换上，
  输入对象与帧槽的 ObjectIdentifier 不变。

## 这样做的代价（为什么还是该进包里）

1. **主线程上解码**：stop / start 都在主线程（与"加一路图片"同一条路），一张 1080p PNG 几毫秒到几十毫秒，4K 大图更久；直播中换字幕时主窗口会顿一下。
   不能挪到后台线程：`ImageInput.thread` 没有锁，stop 与 start 在两个线程上交错（运行表同时删这一路）会漏掉一个线程。
2. **stop → start 之间状态是 noSignal**：start 返回后要等下一拍第一次 push 才回到 live，中间若碰上快照，格子会闪一下"无信号"（≤ 1 拍）。
3. **解码失败就停了**：start 解不开时 state = error、拍点线程不起，PGM 停在上一帧但这一路算出错；包里做的话可以"新图解不开就继续推旧图"。
4. 监视放在 App，headless / 场景文件跑的图片输入没有这个功能。

## 建议（给 W2-A 系，不改契约）

- `ImageInput` 加 `watchesFile: Bool`（Options，默认开）与 `reload()`：后台把新文件解码好，**原子换掉拍点线程读的那个缓冲**（例如 `Mutex<BufferBox>`，
  线程每拍取一次），解不开就保留旧的、`lastError` 写原因、state 不动；监视用同样的事件集合（write / extend / attrib / delete / rename）与 complete 检查。
- 换上的那一拍 `countersBox` 记一次（要让 Stats 能看到"重读了几次"就走 InputCounters，铁律 4；App 现在不记这个数）。
- 包里做完后 App 删掉 `ImageFileWatcher` 与 `InputRuntime.reloadImage`（两处都标了本单的名字）。
