# 照片无损导出（Photo Export）

把 iPhone 相册**零质量损失**搬到电脑的专用工具：在相册里选中照片 → 分享给本 App → 原片字节按拍摄日期归档进沙盒 → 数据线拉到电脑逐文件哈希验证。产品收缩（2026-11）后只保留这一条入口：**分享导出**。

## 它解决什么问题

相册照片想搬去电脑，常见通道全都有坑：

| 通道 | 发生什么 | 结果 |
| --- | --- | --- |
| 微信/QQ 发「原图」 | 服务端按分辨率重编码，EXIF 也被清掉 | 字节已经不是原片 |
| 网盘「极速上传」 | 秒传命中云端压缩副本 | 拉回来的未必是你手机那份 |
| AirDrop | 需要一台 Mac | 本工具面向 Windows 用户的场景 |
| App 内导出到文件/相册 | 常用 `PHImageManager`，会偷偷转码重压 | 无损的敌人是「再压一遍」 |

本工具的原则：**只做字节级复制，禁止一切格式转换和重新编码**；每个文件复制前后各算一次 SHA-256，哈希一致才算成功——用数学代替「看起来没问题」。

## 功能（单页 App：分享导入）

- **分享导出**：在相册里选中照片 → 分享 → **「无损导出」**→ 文件按拍摄时间归档进 Documents 并登记清单（哈希证明链，PC 端拉取校验同权）。模式对齐 Nextcloud/LocalSend 的分享扩展：系统递文件字节级复制（原名保留），只拿不到文件时才降级并在记录里如实标注。同一张照片重复分享会按「内容哈希+文件名」自动跳过，卡片会写明「已登记 X · 另有 Y 项之前已登记过」。
  - **直投兜底通道**：分享面板的 App 行点 **「照片无损导出」**图标，系统把原文件拷进 `Documents/Inbox` 再拉起 App——这条路不依赖 App Group，任何签名方式都通（来源标「分享直投」）。分享扩展依赖 App Group，免费 Apple ID 重签时组权限经常注册不上（Sideloadly 免费版不给 Custom Entitlements），走这条即可。
  - **分享完能否直接跳回 App**：分享扩展主动拉起宿主 App 不是 Apple 保证的能力（论坛 27295）。本版登记完会先用 `photoexport://shared` **尽力尝试拉起**，系统放行就直接进 App 自动登记；被拒才弹窗提示手动打开。真想一步到位，走上面的 App 行直投通道最稳。
  - **导入没反应怎么查**：首页「分享导入」卡片现在直接显示主 App 落到的组名、队列行数/解析条数、收件箱文件数、登记/跳过/失败数和首个错误——拍一张卡片的图就能定位是「扩展写进了另一个容器」还是「文件搬不动」。
  - **一次分享几百张**：扩展同时只向系统要 4 个文件（257 个一起要会被系统节流），逐件落盘记账；扩展会尽力关掉自动锁屏（结果写 `EXT idle-timer` 日志），但扩展进程不保证有 UIApplication 权限——**息屏后系统会挂起扩展、交接暂停**，所以大批量时请保持亮屏（或把「自动锁定」调长）。旧版 90 秒超时会把迟到的文件全丢掉（257 张只登记 145 张的根因），现在超时只提示、不弃单，解锁后继续收完。收尾弹窗如实报数：若系统只交出了选中项的一部分（进程被杀/被取消），会写明「缺的 N 项没到手」。
  - **Live 图（实况）**：走 `PHLivePhoto → PHAssetResource` 原始资源对（Proton Drive/Nextcloud 同款）——每张 Live 登记**两个文件**：`IMG_xxxx.HEIC` 原图 + `IMG_xxxx.MOV` Live 视频，都是原始字节（iCloud 原片自动下载）。所以「分享 100 张 Live」清单里是 200 行，卡片会写明。普通照片仍走文件通道字节级复制。
- **清理已拉取**：电脑端校验全 PASS 后一键删手机端文件腾空间，清单改记 PULLED（哈希保留，证明链不断）。

**无损边界**：登记的是系统从相册递出的**原片字节**（分享扩展按 Nextcloud 同款 `copyItem` 字节级复制，不碰 `PHImageManager` 的渲染图；只在系统只给位图的极罕见情况下降级并在 note 如实标注重编码）。Live 图取 `.photo`/`.pairedVideo` 资源的原始字节。归档目录按拍摄时间：图片读 EXIF、视频读 QuickTime creationDate，都没有则退文件时间。

## 可证明的无损链路

```
设备内：分享扩展 copyItem 原始字节 → App Group 收件箱落盘 → 主 App 登记时算 SHA-256
        → 按拍摄日期归档进 Documents → manifest.csv 记 OK 行（搬不动 = 留在收件箱下轮再试）
数据线：pull.py 拉取 → 逐文件重算 SHA-256 对照 manifest → export-report.csv（固定名，每次覆盖）
        └─ 全 PASS 退出码 0；任何 FAIL/MISSING 退出码 1
```

`manifest.csv`（UTF-8 BOM，Excel 可直接开）就是断点续跑状态，追加式日志、同路径后行覆盖前行，列：

```
relative_path,size,sha256,date_source,asset_id,media_type,favorite,status,exported_at,note
```

## 构建（GitHub Actions → 未签名 IPA → Sideloadly）

与 U盘医生/MyFood 相同的流水线：推送到 `master` 后 Actions 在 macOS 上完成

1. PC 端 unittest（manifest 解析/校验/仅存储 ZIP，纯标准库）
2. `xcodegen generate` 生成 Xcode 工程（工程文件不入库，由 `ios/App/project.yml` 描述）
3. `xcodebuild CODE_SIGNING_ALLOWED=NO` 构建**未签名设备 IPA**
4. `swiftc` 编译并运行核心隔离回归（`ExportPlanner`/`FileHasher`/`ManifestStore`/`TestSupport` + `tests/CoreTests.swift`）
5. 构建 Debug 模拟器包，`-autoSmoke` 四页巡访截图（含真实分享导入链路：投喂收件箱 → drain 登记）、`-autoTest` 应用内自测
6. 上传 artifact 并把 IPA 发布到 Release

安装（两条路，按需要的功能选）：

1. 到仓库 Releases 下载 `photo-export-unsigned.ipa`
2. **Sideloadly（最省事）**：Windows 上用 [Sideloadly](https://sideloadly.io) + 免费 Apple ID 重签安装。免费版没有 Custom Entitlements（Patreon 门禁），**App Group 注册不出来** → 分享扩展会报「无法访问共享容器」，用分享面板 App 行的「照片无损导出」直投通道替代（见上）。
3. **SideStore（要分享扩展按钮就走这条）**：[SideStore](https://sidestore.io) 免费开源、免费 Apple ID 可用。PC 装 iTunes + [iloader](https://iloader.io) 初始安装，手机装免费 App Store 应用 LocalDevVPN 供 7 天刷新；SideStore 从 IPA 的 Mach-O 签名读 entitlements（本仓库 CI 已用 `codesign` 写入 App Group），会到 portal 注册组并下发到两份 profile。
   注意：换装会换 bundle id（Sideloadly 装的是 `...photoexport.FBTKZ8C6QB`），手机端旧容器/清单拿不到——先拉取一遍再换。

## PC 端：拉取路径

App 已开启 iTunes 文件共享（`UIFileSharingEnabled`）。目录布局（2026-11 收缩后）：Documents 根只有 `manifest.csv` + `photos/`（照片按日期归档）+ `logs/`（内部日志）+ `Inbox/`（系统直投暂存）。
懒得记命令就双击仓库根目录的 **拉取.bat**（菜单选数据线或原图对照，参数可通过命令行尾追加，如 `拉取.bat --zip`）。

### 方式 A：数据线脚本（推荐）

> iOS 27 真机注意：重签名 App 的 house_arrest/AFC 通道可能服务错误的容器视图——症状是「目录都列得出来，按名读永远 OBJECT_NOT_FOUND」。这是生态级问题（libimobiledevice#1490），此时换 **方式 B：爱思助手/iMazing 手动导出**。

```sh
pip install -r pc/requirements.txt
python pc/pull.py --list                      # 确认设备已连（需装 iTunes 或「Apple 设备」App 的驱动）
python pc/pull.py --dest D:\相册导出          # 拉取 + 逐文件哈希校验，写 export-report.csv（固定名，每次覆盖）
python pc/pull.py --dest D:\相册导出 --zip    # 全 PASS 后顺手打仅存储 ZIP
```

- 中断（拔线/断电）后**重跑同一条命令即续跑**，已验证文件自动跳过；`--fast-resume` 连哈希都不重算（快，但少一道证明）
- 手机上要先登记过至少一次分享，`Documents/manifest.csv` 存在才能拉

**真原图证明（双路对照，给不放心的人）**：App 导出与相册「导出未修改的原片」背后是**同一个** PhotoKit 原始资源 API（`PHAssetResource` 的 `.photo`/`.video`，编辑版 `.fullSizePhoto` 两边都不碰）——但空口无凭，对出证据来：

1. 手机相册挑 2-3 张**未编辑过**的照片（HEIC/JPG/实况各一最好）→ 分享 → **存储到文件** → 「我的 iPhone」→ 照片无损导出
2. 数据线跑 `python pc/pull.py --dest 目标目录 --compare-orphans`（这些系统导出的文件会进 `_原图对照/` 并自动与清单哈希逐个比对）
3. `[对照] IMG_xxxx.HEIC ↔ ... PASS（字节一致）` = 系统 UI 导出的字节和我们导出的字节**完全相同**，真原图实锤

### 方式 B：爱思助手/iMazing 手动导出 + 校验兜底

在爱思助手「应用游戏 → 本机应用 → 文件共享」（或 iMazing）把 App 的 `Documents/` 整个拖出来，然后：

```sh
python pc/verify.py D:\相册导出            # 对 manifest 全量哈希校验
python pc/verify.py D:\相册导出 --zip
```

脚本跑不通时这条是兜底；校验逻辑与方式 A 完全一致。

### 方式 C：传输护甲（微信传大包）

微信只对**图片/视频**二次压缩，按**文件**发不压。校验通过后：

```sh
python pc/pull.py --dest D:\相册导出 --zip
```

生成 **ZIP_STORED 仅存储模式**包（字节原封不动，只加目录和 CRC32），微信发这个 zip 给自己/电脑，解压后 `python pc/verify.py 解压目录` 再验一次即可。**红线：不要用微信/QQ 直接发原图文件、不要用网盘「极速上传」**。

## 本地开发

```sh
cd ios/App
brew install xcodegen   # 首次（macOS）
xcodegen generate       # 生成 App.xcodeproj 后用 Xcode 打开
```

PC 端测试（Windows 即可真跑）：`python -m unittest discover -s pc -p 'test_*.py'`

## 测试协议

- `run_simulator_tests.sh <udid> <smoke|autotest>`：App 用 `-autoSmoke`/`-autoTest` 启动，通过 `tmp/<mode>/now-*`、`ack-*`、`done.txt`、`result.txt` 与 runner 握手（页面截图、断言结果、要求进程正常退出）。smoke 含真实分享导入链路（往 App Group 收件箱投两张 PNG 再走真实 drain），轮询窗口默认 720 秒（`PE_POLL_SECONDS` 可缩）。
- `test_simulator_runner.sh`：用 mock `xcrun` 验证 runner 的 7 种场景（通过/提前退出/崩溃/失败/超时/缺截图/缺握手），可在无 Mac 环境运行。

## 真机验收清单

1. 装好 App（SideStore/Sideloadly，见上文）→ 相册选 10 张照片 → 分享 → 「无损导出」
2. 回 App：卡片显示「已登记 10 项」（重复分享同一批会显示跳过数量）
3. 数据线连电脑，`python pc/pull.py --dest D:\试导出` → 全 PASS（报 OBJECT_NOT_FOUND 就走方式 B：爱思助手/iMazing 手动导出）
4. 抽 1 张人工抽查：`certutil -hashfile 文件 SHA256` 与 manifest.csv 里那行一致
5. `--zip` 后微信把 zip 发给自己，PC 解压再 `verify.py` 通过
6. 大批量（几百张）：保持亮屏（扩展会尽力关自动锁屏）；中途息屏也不丢——解锁后扩展继续收，超时只提示不弃单
