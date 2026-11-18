# Research：Finder 右键菜单「剪切 / 粘贴（移动到此处）/ 撤销上一次移动」的最佳实践

| 项目 | 内容 |
|---|---|
| 类型 | 只读调研，无代码改动 |
| 日期 | 2026-11-17 |
| 方法 | 仅取一手来源（Apple 文档、产品官方文档、开源代码）。取不到的写 UNVERIFIED |
| 取证限制 | developer.apple.com 的 API 页是 JS 渲染，WebFetch 只拿到标题，**API 行为条目无法逐字引用**；forkliftapp.com/help 返回 404；pathfinder.cocoatech.com 连接中断；Commander One、Transmit、iRightMouse 等未取到文档 |

## Question

RClick 计划：Cut 只把 Finder 选区标记为「待移动」；Paste 把待移动项直接移入右键所在文件夹且不弹确认；Undo 还原上一次移动；同卷用 rename，跨卷先复制再删除源；扩展只负责渲染，文件操作在主程序。同类产品怎么做？Apple 推荐哪些 API？安全清单是什么？

## Short answer

1. Finder 自己没有 Cut，只有 Copy 后 Option-Command-V「移动到此处」；Apple 文档对碰撞、跨卷、Undo 细节几乎不写（能取到的只有一行快捷键说明）。
2. 取到文档的文件管理器（Nimble Commander、Marta）都没有文档化的「待剪切」状态；Nimble Commander 明确用 Cmd-C + Opt-Cmd-V 代替 Cut，待移动项就是剪贴板里的普通文件路径。
3. Apple 的文件管理指南写明：同卷 move 不产生新版本，跨卷 move 等同 copy，且要放到后台队列；跨卷不是原子操作，必须自己保证「复制成功才删源、失败清理半成品」。
4. 不能确认第三方移动会进入 Finder 的 Edit > Undo（UNVERIFIED，倾向不会），所以 RClick 必须自带 Undo，并且只对「自己记录过的移动」生效。
5. 无确认 Paste 可以接受的前提是：绝不覆盖（碰撞时自动改名）、可撤销、失败不丢数据。

## Comparison table

| 产品 | Cut 的表示 | 碰撞 | 跨卷 | Undo | 来源 |
|---|---|---|---|---|---|
| Finder | 无 Cut。Copy 后用 Option-Command-V，指令描述为「Move the files in the Clipboard from their original location to the current location」 | UNVERIFIED（Apple 页面未取到；实际 Finder 弹 Replace / Keep Both / Stop，仅属一般经验） | UNVERIFIED | Cmd-Z「Undo the previous command」；Edit > Undo Move 的具体范围 UNVERIFIED | [S1] |
| Nimble Commander | 无独立 Cut。Cmd-C 后 Opt-Cmd-V 「Move Item Here」，条件是剪贴板里是文件系统路径 | 帮助页未写（UNVERIFIED） | Copy/Move 对话框有「verify result」复选框，属于可选校验 | 帮助页未提 | [S2] |
| Marta | 无 Cut 的文档。主打双栏、不用剪贴板；移动到非活动栏「不弹对话框，立即开始」 | 页面未写 | 页面未写 | 页面未写；Delete 永久，「you won't be able to restore them」 | [S3][S4] |
| ForkLift | 未取到（help 页 404） | UNVERIFIED | UNVERIFIED | UNVERIFIED | 无 |
| Path Finder | 未取到（连接中断） | UNVERIFIED | UNVERIFIED | UNVERIFIED | 无 |
| Commander One / Transmit | 未查询 | UNVERIFIED | UNVERIFIED | UNVERIFIED | 无 |
| Finder 扩展类（Cut and Paste 工具、iRightMouse 等） | 未取到官方文档 | UNVERIFIED | UNVERIFIED | UNVERIFIED | 无 |

## Findings

### F1. Finder 的「移动」是 Copy + 粘贴时换动词，没有「待剪切」状态

- Apple 键盘快捷键页把 Option-Command-V 描述为：「Move the files in the Clipboard from their original location to the current location.」；Command-Z 为「Undo the previous command」，并说明有的 App 可多步撤销。[S1]
- 含义：Finder 的待移动项就是普通剪贴板文件，没有「已剪切」标记、也没有视觉淡化。这是 Finder 的既定心智模型，RClick 的「Cut 只标记」与它不同，需要自己的 UX 提示（见推荐 5）。
- UNVERIFIED：Finder 在碰撞时的具体对话框、跨卷行为、Edit > Undo Move 能撤销到什么程度。Apple 的 mac-help 页面（mchlp1171、mchlp2271）取到的是目录页，没有这些正文。

### F2. 文件管理器普遍把「Cut」降级成「Copy + 移动粘贴」，没有私有状态

- Nimble Commander 帮助页：`Opt + Cmd + V` 把剪贴板上路径指向的项目移入活动面板的文件夹；「No dedicated cut command is documented」，最接近的是 Cmd-C 后 Opt-Cmd-V（页面写作 "Move Item Here"）。F5/F6 对话框含「preserve attributes」和「verify」选项。[S2]
- Nimble Commander 帮助页没有提碰撞策略和 Undo。[S2]
- Marta 文档强调双栏免剪贴板，移动到非活动栏无对话框；删除永久且不可恢复。[S3][S4]
- 含义：同类产品里，「标记待移动」最常见的载体是系统剪贴板里的文件 URL；RClick 若用私有状态，需要明确它何时失效（见 F6）。

### F3. Apple 对 move 的语义有明确文字

出自 File System Programming Guide（Managing Files and Directories）[S5]：

- 「The semantics for move and copy operations are the same as in the Finder.」
- 「Move operations on the same volume do not cause a new version of the item to be created. Move operations between volumes behave the same as a copy operation.」
- 「the current process must have permission to read the items and move or copy them to the new location.」
- 移动和复制可能很久，FileManager 是同步的，「recommended that you execute any such operations on a concurrent dispatch queue and not on your app's main thread」。
- `removeItem` 是永久删除，「these methods do not move the file to the Trash」。

### F4. API 行为（只有标题取到，以下为一般知识，UNVERIFIED，需对照 Apple 文档页）

- `moveItem(at:to:)`：目标已存在则抛错（`fileWriteFileExists`），不覆盖；目标路径必须含最终文件名。
- `replaceItemAt(_:withItemAt:)`：用于「安全覆盖已有文件」，要求原项存在，会消耗新项。**不适合**「移动进文件夹」这类场景，因为 RClick 不应覆盖。
- `trashItem(at:resultingItemURL:)`：移入废纸篓，可拿到废纸篓中的新 URL，名字冲突时可能被改名。沙盒下需要有写权限，且可能读不到结果 URL。
- `NSFileCoordinator`：共享位置（iCloud、文件提供者）应使用 `coordinate(writingItemAt:options:.forMoving ...)`。Apple 指南只提及「Techniques for Reading and Writing Files Without File Coordinators」，未在该页展开 [S5]。
- 以上均来自 WebFetch 的二手摘要，未逐字取到 developer.apple.com 正文。

### F5. 剪贴板类型与「cut」标记惯例

- 本次未取到任何 Apple 文档说明 Finder 剪贴板的 cut 标记。`public.file-url`、`NSPasteboard.PasteboardType.fileURL` 是标准文件 URL 类型（一般知识，UNVERIFIED）；`com.apple.finder.node` 是否存在及用途 UNVERIFIED。
- 没有查到跨 App 通用的「已剪切」约定（Windows 的 Preferred DropEffect 在 macOS 无对应）。UNVERIFIED。
- 含义：用私有状态保存待移动项（主程序内存或 App Group），不要依赖剪贴板标记；是否同时写入剪贴板是产品选择。

### F6. 第三方移动是否进入 Finder 的 Edit > Undo

- UNVERIFIED。未找到 Apple 文档说明第三方 App 的 FileManager 移动会被 Finder 记录。Finder 的撤销栈属于 Finder 进程自己的 UndoManager，沙盒 App 的操作不会写入。结论：RClick 必须自己维护 Undo 记录。

### F7. 同类 Finder 扩展工具

- 未取到 iRightMouse 等工具的官方文档，其 Cut/Paste 实现、碰撞策略均 UNVERIFIED，本文不做结论。

## Safety checklist

标注：「来源」为 [S?] 的是有一手依据；其余是工程惯例或一般知识，UNVERIFIED，需实测。

| 项目 | 做法 | UX | 来源 |
|---|---|---|---|
| 名称碰撞 | 目标已存在时不覆盖、不合并，自动改名（如 `name 2`）或跳过该项 | 结束提示「N 项已改名」；不做静默覆盖 | moveItem 不覆盖：UNVERIFIED |
| 同卷移动 | 用 `moveItem`（rename），不复制 | 即时完成 | [S5] |
| 跨卷移动 | 复制到目标，校验（大小/存在），成功后再删除源；失败则清理半成品，源不动 | 后台队列，进度或完成通知 | [S5] 说跨卷等同 copy；校验与清理是惯例 UNVERIFIED。Nimble Commander 提供可选 verify [S2] |
| 部分失败 | 逐项处理，记录成功项；失败项留在待移动列表或报告 | 汇总「M 项成功，K 项失败」，列出原因 | UNVERIFIED |
| 同文件夹粘贴 | 源父目录等于目标时直接跳过（不改名、不复制） | 无操作，不弹窗 | UNVERIFIED |
| 粘贴到源的子孙目录 | 目标在源路径前缀内时拒绝 | 提示「不能把文件夹移动到自身内部」 | UNVERIFIED |
| 符号链接 | 移动链接本身，不解引用；别遍历链接做前缀判断 | 无 | UNVERIFIED |
| 包（.app、.pkg 等） | 当作单个项目整体移动 | 无 | UNVERIFIED |
| 锁定/占用文件 | 抛错即报告，不强改标志位 | 在失败汇总中列出 | UNVERIFIED |
| 外置/网络卷 | 视为跨卷；可能不支持废纸篓或 rename；断开则中止并保留源 | 报告「卷不可用」 | Marta：废纸篓「if supported by the file system」[S4] |
| 文件名过长 | 目标卷限制导致失败时报告，不截断 | 失败汇总 | UNVERIFIED |
| 权限 | 沙盒下对源和目标都要有书签授权；缺少授权走 `PermissionService.promptForPermission` | 先授权后执行；用户取消则整批不动 | [S5] 要求读写权限；项目内 CLAUDE.md 已定义授权流程 |
| 主线程 | 所有 move/copy 放后台 | 不卡 UI | [S5] |

## Open points (UNVERIFIED)

1. Finder Option-Command-V 的碰撞对话框、跨卷细节、Edit > Undo Move 的撤销范围：需要在真实 Finder 上实测（本任务禁止操作 Finder）。
2. 第三方 App 的移动是否出现在 Finder 的 Undo 菜单：需实测。
3. ForkLift、Path Finder、Commander One、Transmit 的 Cut/Paste 与碰撞策略：官方文档未取到。
4. Finder 扩展类工具（iRightMouse 等）的实现：官方文档未取到。
5. `com.apple.finder.node` 与 Finder 剪贴板有没有 cut 标记：未查到 Apple 文档。
6. `moveItem` / `replaceItemAt` / `trashItem` / `NSFileCoordinator` 的逐字 Apple 文档：developer.apple.com 页面渲染失败，建议在 Xcode 文档里复核。
7. 沙盒下跨卷移动是否需要对两个卷分别持有书签：按 BookmarkManager 前缀匹配规则推断需要，未找到 Apple 明文。

## Recommendations for RClick (ranked)

1. **不覆盖是底线。** 无确认 Paste 只能配「碰撞自动改名、绝不覆盖」。这是无确认设计唯一可接受的前提。
2. **跨卷严格「复制 -> 校验 -> 删源」，失败清理半成品、源保持原样。** 校验至少比较存在性与大小；校验失败不删源。依据 [S5]（跨卷等同复制）。
3. **Undo 自己做。** 只记录最近一次批量移动的「原路径 -> 新路径」列表（含改名后的实际路径），Undo 把每项移回原位；原位被占用时改名回退并报告。不要依赖 Finder 的 Edit > Undo（F6）。跨卷移动的 Undo 也是跨卷移动，需同样的安全流程。
4. **逐项处理并汇总结果。** 部分失败不回滚成功项；成功项进入 Undo 记录，失败项报告原因。
5. **Cut 要有可见反馈。** Finder 没有 cut 的视觉标记（F1），RClick 的待移动状态要在菜单里体现（如 Paste 标题带条数），并定义清除时机：Paste 完成、再次 Cut、主程序退出、源项已不存在。
6. **预检拒绝：** 同文件夹粘贴（跳过）、粘贴到自身子孙目录（拒绝）、源已不存在（跳过并报告）。
7. **沙盒授权前置。** 对源和目标父目录都检查 `hasAccess(to:)`，缺失就先 prompt，再动手；整批开始前授权完毕，避免做到一半弹窗（与 slice 7/8 的 lease 方向一致）。
8. **所有文件操作放后台执行器，扩展只发 `.click` 并等待 `.actionAck`。** 与现有架构一致。
9. **上线前在真机补验 Open points 1、2、7。**

## Sources

- [S1] Apple, Mac keyboard shortcuts（Finder and system shortcuts: Option-Command-V, Command-Z）: https://support.apple.com/en-us/102650
- [S2] Nimble Commander help（Copy/Move/Paste、Move Item Here、verify 选项）: https://raw.githubusercontent.com/mikekazakov/nimble-commander/main/Docs/Help.md ；README: https://github.com/mikekazakov/nimble-commander
- [S3] Marta docs index: https://marta.sh/docs/
- [S4] Marta file operations: https://marta.sh/docs/core/file-operations/
- [S5] Apple, File System Programming Guide, Managing Files and Directories: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/ManagingFIlesandDirectories/ManagingFIlesandDirectories.html
- 取到标题但正文不可用（仅一般知识，不作引用）：FileManager `trashItem`、`moveItem`、`replaceItemAt` 的 developer.apple.com 页面
- 不可达：forkliftapp.com/help（404）、pathfinder.cocoatech.com（连接中断）；Apple mac-help mchlp1171、mchlp2271 只返回目录页
