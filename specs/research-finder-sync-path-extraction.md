# 研究记录：FinderSync 扩展如何取得选中项的真实路径（含字面 `%` 的文件名）

| 项目 | 内容 |
|---|---|
| 类型 | 只读研究，仅依据一手来源；无法追溯到一手来源的结论标 UNVERIFIED |
| 日期 | 2026-11-17 |
| 仓库基线 | RClick `d63c29c` |
| 涉及文件 | `FinderSyncExt/FinderSyncExt.swift`、`RClick/Runtime/ActionService.swift`（仅阅读） |

> **后续状态（2026-11-18，提交本文时补充）**：下文的出发点（“真机测试中主程序收到多解码一层的字符串”）后来被证伪。
> - 真机复验（#5 的第二次运行）确认原始路径从扩展一路保持到删除：之前的“失败”是测试脚本按 AppleScript 的 `items` 顺序估算坐标、点中了相邻的同级行（Finder 的显示顺序与 AppleScript 顺序不同；当时 Finder 自己的菜单标题已写出同级项的名字），不是产品的解码。
> - 下文 Findings 第 4 节（本仓库的实际调用链）关于“`ActionService` 在 `d63c29c` 上有 7 处解码”的描述是对当时 `main` 的准确描述；这些解码已在 #5 / PR #29 中移除，`Shared/Clipboard.swift` 里的两处解码已在 #28 中移除。
> - Recommendation 一节对访问器的建议（`.path` 或 `path(percentEncoded: false)`）与之后的 Foundation 实验一致：对真实文件 URL 它们都保留字面 `%`，只有 `URL(string: "file://" + 原始路径)` 这类构造才会多解一层。

## Question

扩展用 `FIFinderSyncController.default().selectedItemURLs()` 后 `.map { $0.path }`，经分布式通知发给主程序，主程序调用
`FileManager.removeItem(atPath:)`。真机测试中选中 `%2544ocuments`（旁边还有同级 `%44ocuments`），主程序收到的字符串却是
`%44ocuments`，即被多解码了一层。应当用哪个访问器取路径，才能让 `%2544ocuments`、`100%25 done.txt` 这类名字原样往返？

## Short answer

1. 在已读到的 swift-foundation 源码里，`URL.path`（文件 URL）只做一次百分号解码，不会多解一层；`path(percentEncoded: false)` 同样只解一次。
2. 仓库里 `ActionService.swift` 在收到路径后**又**调用了 `removingPercentEncoding`（190、371、543 等行）。前提“接收后不解码”在 `d63c29c` 上不成立，这是眼下最可能的第二次解码。
3. Apple 文档没有说明 `selectedItemURLs()` 返回的 URL 种类与编码；读过的开源 FinderSync 项目全部直接用 `.path`，没有一个处理 `%`。
4. 推荐：扩展端一律 `url.path(percentEncoded: false)` 或 `.path`（发送前记录两者与 `absoluteString`），主程序端移除所有 `removingPercentEncoding`，真机日志用 Findings 5 的清单收尾。

## Findings

### 1. Apple 对 `selectedItemURLs()` / `targetedURL()` 的描述

来源：Apple 文档 JSON 端点
`https://developer.apple.com/tutorials/data/documentation/findersync/fifindersynccontroller/selecteditemurls().json` 与 `.../targetedurl().json`
（`developer.apple.com/documentation/...` 页面需要 JS，WebFetch 取不到正文，改用该 JSON 端点，2026-11-17 读取）。

- `selectedItemURLs()`：签名 `func selectedItemURLs() -> [URL]?`，“An array of items currently selected in the Finder window.”
- `targetedURL()`：签名 `func targetedURL() -> URL?`，“The URL of the Finder's current target.” 讨论段称它返回用户 Control 点击的那一项的 URL。
- 两者都只在 `menu(for:)` 或该方法创建的菜单动作内返回有效值；所选项在受管目录之外（例如点工具栏按钮）时返回 `nil`。
- 文档**没有**说明：是 file URL 还是 file reference URL（`file:///.officeflags/id=...`），也没有说明编码方式。UNVERIFIED（见 Open points）。

### 2. `URL.path` 等访问器的精确语义（swift-foundation）

读取的提交：swift-foundation `main` = `9402598280de9eade9b307d39d3c5106244ec4dc`，
swift-corelibs-foundation `main` = `7926d06941951bd3c1dd1ac523e3429391ca1322`（2026-11-17 经 raw.githubusercontent.com 读取）。
macOS 自带的 Foundation 为闭源构建；下面的源码只代表开源实现，macOS 15 上的行为见 Open points。

文件：`Sources/FoundationEssentials/URL/URL_Swift.swift`（`_SwiftURL`）

- 第 468–479 行 `absolutePath(percentEncoded:)`：`true` 时直接返回 `_parseInfo.path`（保持编码）；`false` 时 `Parser.percentDecode(_parseInfo.path)`，**一次解码**。
- 第 481–489 行 `var path`：`if isFileURL { return fileSystemPath() }`。
- 第 574–577 行 `fileSystemPath(style:)`：`absolutePath(percentEncoded: true)` 后交给 `fileSystemPath(for:style:)`。
- 第 566–572 行：posix 样式为 `decodeFilePath(slashDropper(urlPath))`。
- 第 531–535 行 `decodeFilePath`：注释 “Don't decode "%2F" or "%00"”，调用 `Parser.percentDecode(path, excluding: [/, 0])`，**一次解码**，保留 `%2F` 和 `%00`。
- 第 579–586 行 `withUnsafeFileSystemRepresentation`：`_isCanonicalFileURL` 时取 `fileSystemPath().withCString`，否则
  `fileSystemPath().withFileSystemRepresentation`。同样是一次解码（再做规范化）。
- 第 935–941 行：`isFileReferenceURL()` 为 `isFileURL && _parseInfo.pathHasFileID`；第 946–953 行 `convertingFileReference()` 通过
  `bridgeToNSURL().filePathURL` 转成路径 URL，失败则返回 `com-apple-unresolvable-file-reference-url:`。

文件：`Sources/FoundationEssentials/URL/URL.swift`（公开 API 外壳）

- 第 1102–1104 行 `public var path: String { _url.path }`，文档注释称新代码应使用 `path(percentEncoded:)`。
- 第 1121–1123 行 `path(percentEncoded:)`，文档：“removes any percent-encoding and returns the unencoded path”。
- 第 1211–1213 行 `withUnsafeFileSystemRepresentation`，文档：“null-terminated C string with canonical UTF-8 encoding”。
- 第 936 行起 `absoluteString`：返回的是**保持百分号编码**的完整 URL 字符串。对 `file:///tmp/%2544ocuments` 做 `removingPercentEncoding`
  得 `/tmp/%44ocuments`，再做一次得 `/tmp/Documents`。

文件：swift-corelibs-foundation `Sources/Foundation/NSURL.swift`

- 第 416–430 行 `NSURL.path`：`CFURLCopyAbsoluteURL` 后 `CFURLCopyFileSystemPath(…, kCFURLPOSIXPathStyle)`，一次解码（CF 实现，未逐行追到 CFURL.c，标 UNVERIFIED）。
- 第 487 行起 `fileSystemRepresentation`：同样基于 CF 的文件系统路径。
- 第 197–207 行 `init(fileURLWithPath:isDirectory:relativeTo:)`：以路径构造（`_CFURLInitWithFileSystemPathRelativeToBase`），路径里的 `%` 会被当作字面字符并编码成 `%25`。

结论：

- 能多解一层的只有**调用方自己**对已解码字符串再次 `removingPercentEncoding`，或用 `URL(string:)` / `URL(fileURLWithPath: someURL.absoluteString)` 之类把编码串当路径。
- `URL.path`、`path(percentEncoded: false)`、`withUnsafeFileSystemRepresentation` 对一个正确构造的 file URL 都只解一次，互相等价（除 `%2F` 与 `%00` 的处理：`.path` / FS 表示保留它们，`path(percentEncoded: false)` 不排除，见 `percentDecode(_parseInfo.path)` 无 `excluding`）。
- 若 Finder 交给扩展的 URL 本身就被**双重编码**（`%2544ocuments` 被编码成 `%252544ocuments`），任何访问器都会给出少一层的字符串；本研究读到的一手资料无法证明或排除这一点（UNVERIFIED）。

### 3. 开源 FinderSync 项目如何取路径

下表“提交”为该文件最近一次修改的提交；行号按 2026-11-17 默认分支读取。

| 仓库 | 文件 | 取路径方式 | 处理 `%`？ |
|---|---|---|---|
| Ji4n1ng/OpenInTerminal，提交 `9a399994239a6d3c05b7851aa17c703486d574bb` | `OpenInTerminalFinderExtension/FinderSync.swift` 第 193–199、279 行 | `selectedItemURLs()` 为空则退回 `targetedURL()`，保留 `[URL]`；复制路径用 `urls.map { $0.path }` | 否。仅有 shell 转义 `specialCharEscaped()`（第 233 行注释里也是 `url.path.specialCharEscaped2`） |
| CodeEditApp/CodeEdit，提交 `184e086759d75b1013a6515f01c68d4252b4a804` | `OpenWithCodeEdit/FinderSync.swift` 第 48、57 行 | `files.append("\(obj.path);")` | 否 |
| alienator88/Pearcleaner，提交 `2bf48d12e0adcf39b4ea6f5790a55464cf175a2a` | `FinderOpen/FinderOpen.swift` 第 52、58 行 | `firstSelectedItem.path` | 否 |
| wflixu/RClick（上游），`main` | `FinderSyncExt/FinderSyncExt.swift` 第 673–675、715–717 行 | `selectedItems.map { $0.path }` | 否（扩展端）；接收端见 Findings 4 |
| sarensw/MacPacker，`main` | `FinderExtension/FinderSync.swift` 第 155、280 行 | `selectedItemURLs()` / `targetedURL()`，日志用 `url.path` | 否 |
| Mortennn/FiScript，`master` | `Finder Extension/FinderSync.swift` 第 98 行 | `URL(fileURLWithPath: path.absoluteString)` | 否；这个写法把编码串当路径，含 `%` 或空格时会出错（本文未复现，只说明风险，UNVERIFIED 是否真出错） |

没有任何一个被读取的项目使用 `withUnsafeFileSystemRepresentation`、`path(percentEncoded:)` 或 `fileSystemRepresentation`。
提交 SHA 只给出了前四项的完整值；MacPacker、FiScript、上游 RClick 读取的是分支头，未记录 SHA（UNVERIFIED 到具体提交）。

### 4. 本仓库的实际调用链（阅读 `d63c29c`）

- 扩展端：`FinderSyncExt/FinderSyncExt.swift` 第 673–675 行与 715–717 行，`selectedItems.map { $0.path }`，与 OpenInTerminal 等一致。
- 接收端：`RClick/Runtime/ActionService.swift`
  - 第 190 行（隔空投送）：`let decodedPath = item.removingPercentEncoding ?? item`
  - 第 371 行（删除）：`let decodedPath = item.removingPercentEncoding ?? item`
  - 第 543 行（新建文件目标目录）：`rawPath.removingPercentEncoding ?? rawPath`
  - 第 134、244、290、323 行：`dirPath.removingPercentEncoding ?? dirPath`
- 另有 `Shared/Clipboard.swift` 第 11、31 行与 `Shared/AppPresets.swift` 第 120 行对路径再解码。
- 按 Findings 2，扩展端 `.path` 对 `…/%2544ocuments` 得到字面 `%2544ocuments`；接收端再解一次得 `%44ocuments`，与真机现象吻合。
  这是**与现象一致的推断**，不是已被日志证实的结论。

### 5. 已知 Apple 反馈 / 论坛帖（与路径或编码相关）

搜索“FinderSync selectedItemURLs percent encoded”没有找到专门讲百分号编码的 Apple 反馈或论坛帖。找到的相邻条目：

- Apple Developer Forums 718960（selectedItemURLs 仅在 `menu(for:)` 及其动作内有效，其他处为 nil）：https://developer.apple.com/forums/thread/718960 （仅取自搜索摘要，未读全文）
- Apple Developer Forums 717098（沙盒扩展里 `selectedItemURLs()` 有返回值但无法读文件）：https://developer.apple.com/forums/thread/717098 （同上）
- Open Radar rdar://42874694：期望 `selectedItemURLs()` 获得 “User Selected File” 沙盒访问权，示例输出为普通 `file:///Users/user/Desktop/...`：http://www.openradar.me/42874694 （取自搜索摘要）
- Open Radar rdar://34362783（/Volumes 下变更不通知）：https://openradar.appspot.com/34362783 （与编码无关）

## Open points (UNVERIFIED)

- Finder 交给扩展的 URL 到底是 file path URL 还是 file reference URL，`absoluteString` 里 `%` 是否被编成 `%25`：Apple 文档未写，未找到一手说明。
- macOS 15 随系统发布的 Foundation 是闭源构建，其 `URL.path` 行为只能由开源 swift-foundation 推断；二者是否逐字一致未验证。
- `CFURLCopyFileSystemPath` 的 CF 实现（NSURL.path 路径）未逐行追踪。
- 真机“多解一层”到底发生在扩展端还是 `ActionService` 的 `removingPercentEncoding`：只有推断，缺日志。
- 是否存在 Apple Feedback ID 或发行说明讲 FinderSync URL 与 `%`：未找到。
- Apple 文档站正文需要 JS，WebFetch 取不到；本文用其 JSON 数据端点读取，未做截图交叉验证。

## Recommendation

1. 访问器：扩展端把 `selectedItemURLs()`（为空再 `targetedURL()`）得到的 `URL` 用
   `url.standardizedFileURL.path(percentEncoded: false)` 或 `url.path` 转成字符串；二者对 file URL 等价。
   若要让 `%2F` 之类也不被吞掉，最稳的是 `url.withUnsafeFileSystemRepresentation { String(cString: $0!) }`（文档保证是文件系统表示）。
   需要时先判断 `url.isFileURL`，file reference URL 可先取 `url.filePathURL`。
2. 传输：路径字符串一次编码、一次解码，**只在扩展端把 URL 转路径，接收端不得再做任何百分号解码**。
   移除 `ActionService.swift` 第 134、190、244、290、323、371、543 行，`Clipboard.swift` 第 11、31 行，`AppPresets.swift` 第 120 行的 `removingPercentEncoding`
   前，先确认没有别的调用方传入的是编码串（需审计上游发送点，不在本研究范围）。
3. 测试：给 `%2544ocuments`、`%44ocuments`、`100%25 done.txt`、含空格与 `#`、含 `%2F` 字面名的夹具各一个，做扩展到 `removeItem` 的往返断言。
4. 真机日志（在 `FinderSyncExt.swift` 673、715 行附近，只打日志、不改行为），对每个选中 URL 记录：
   - `url.absoluteString`、`url.path`、`url.path(percentEncoded: false)`、`url.isFileURL`、`(url as NSURL).isFileReferenceURL()`；
   - `url.withUnsafeFileSystemRepresentation` 得到的字符串，以及其 UTF-8 字节的十六进制；
   - 发出的 payload 字符串（十六进制）与 `ActionService` 入口收到的字符串（十六进制），二者逐字节对比；
   - 删除前 `FileManager.default.fileExists(atPath:)` 对收到串与其 `removingPercentEncoding` 结果各一次。
   判读：若扩展端 `.path` 已是 `%44ocuments`，问题在 Finder 给的 URL（走 Open points 第 1 条，需提 Feedback）；若扩展端是 `%2544ocuments` 而接收端是
   `%44ocuments`，问题就是接收端解码。

## Sources

- Apple，FIFinderSyncController.selectedItemURLs()：https://developer.apple.com/documentation/findersync/fifindersynccontroller/selecteditemurls() （数据端点 `https://developer.apple.com/tutorials/data/documentation/findersync/fifindersynccontroller/selecteditemurls().json`）
- Apple，FIFinderSyncController.targetedURL()：https://developer.apple.com/documentation/findersync/fifindersynccontroller/targetedurl()
- Apple，URL.path(percentEncoded:)、URL.path、URL.withUnsafeFileSystemRepresentation(_:)、NSURL.fileReferenceURL()：`https://developer.apple.com/tutorials/data/documentation/foundation/url/...` 对应页面
- swift-foundation `URL_Swift.swift` / `URL.swift`，提交 `9402598280de9eade9b307d39d3c5106244ec4dc`：https://github.com/swiftlang/swift-foundation/tree/main/Sources/FoundationEssentials/URL
- swift-corelibs-foundation `NSURL.swift`，提交 `7926d06941951bd3c1dd1ac523e3429391ca1322`：https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/Foundation/NSURL.swift
- Ji4n1ng/OpenInTerminal `FinderSync.swift`：https://github.com/Ji4n1ng/OpenInTerminal/blob/master/OpenInTerminalFinderExtension/FinderSync.swift
- CodeEditApp/CodeEdit：https://github.com/CodeEditApp/CodeEdit/blob/main/OpenWithCodeEdit/FinderSync.swift
- alienator88/Pearcleaner：https://github.com/alienator88/Pearcleaner/blob/main/FinderOpen/FinderOpen.swift
- wflixu/RClick：https://github.com/wflixu/RClick/blob/main/FinderSyncExt/FinderSyncExt.swift
- sarensw/MacPacker：https://github.com/sarensw/MacPacker/blob/main/FinderExtension/FinderSync.swift
- Mortennn/FiScript：https://github.com/Mortennn/FiScript
- Apple Developer Forums 718960 / 717098、Open Radar 42874694 / 34362783（见 Findings 5）
- 本仓库 `RClick/Runtime/ActionService.swift`、`FinderSyncExt/FinderSyncExt.swift`、`Shared/Clipboard.swift`、`Shared/AppPresets.swift`（基线 `d63c29c`）
- Swift Evolution 中没有专门的 URL 路径语义提案被查阅；未使用。
