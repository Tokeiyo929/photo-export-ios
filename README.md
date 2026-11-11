# 照片无损导出（Photo Export）

把 iPhone 相册**零质量损失**搬到电脑的专用工具：iPhone 上按拍摄日期导出原片字节，数据线拉到电脑后逐文件哈希验证。

## 它解决什么问题

相册照片想搬去电脑，常见通道全都有坑：

| 通道 | 发生什么 | 结果 |
| --- | --- | --- |
| 微信/QQ 发「原图」 | 服务端按分辨率重编码，EXIF 也被清掉 | 字节已经不是原片 |
| 网盘「极速上传」 | 秒传命中云端压缩副本 | 拉回来的未必是你手机那份 |
| AirDrop | 需要一台 Mac | 本工具面向 Windows 用户的场景 |
| App 内导出到文件/相册 | 常用 `PHImageManager`，会偷偷转码重压 | 无损的敌人是「再压一遍」 |

本工具的原则：**只做字节级复制，禁止一切格式转换和重新编码**；每个文件复制前后各算一次 SHA-256，哈希一致才算成功——用数学代替「看起来没问题」。

## 功能（三个标签页）

- **导出**：一键把全相册原片写进 App 沙盒 `Documents/`，按拍摄日期归档成 `2026/2026-03-15/IMG_1234.HEIC`（无拍摄日期 → 资源文件时间 → `UNDATED/`）；显示数量、预计大小、手机剩余空间预警；**大相册可设每批上限（默认 2 GB，见下文「分批导出」）**；导出中保持屏幕常亮，可随时取消（扫描阶段也可以），重进续跑（已成功的文件自动跳过，单文件失败只记 FAIL 不影响其余）。
- **记录**：manifest.csv 统计与最近记录（OK 待拉取 / PULLED 已拉取清理 / FAIL 三种状态）；「复核全部文件哈希」在设备上重算一遍已导出文件的 SHA-256。
- **电脑**：数据线拉取的操作指引。

**无损边界（v1 口径）**：导出的是相册里的**原片**（`.photo`/`.video`/`.pairedVideo`/`.altPhoto`），Live Photo 导出原片+实况视频同名一对，RAW+JPEG 把 RAW 一并带上；照片上的滤镜/裁剪**编辑不套用**——要编辑版就意味着重编码，与「原片无损」冲突。隐藏与最近删除不在导出范围。

## 可证明的无损链路

```
设备内：writeOriginal 原始字节 → tmp 写盘 → SHA-256 → 移入正式目录 → 复算 SHA-256
        └─ 一致 → manifest.csv 记 OK 行；不一致 → 记 FAIL 并删除落盘文件
数据线：pull.py 拉取 → 逐文件重算 SHA-256 对照 manifest → export-report-*.csv
        └─ 全 PASS 退出码 0；任何 FAIL/MISSING 退出码 1
```

`manifest.csv`（UTF-8 BOM，Excel 可直接开）就是断点续跑状态，追加式日志、同路径后行覆盖前行，列：

```
relative_path,size,sha256,date_source,asset_id,media_type,favorite,status,exported_at,note
```

## 大相册：分批导出（装不下整个相册时）

相册几万张、几十 GB，手机剩余空间装不下整库时，走「导一批 → 拉取校验 → 清理 → 下一批」循环：

1. **导出页**把「每批导出上限」选成合适档位（可选 500 MB/1/2/4/8 GB/不限；剩余空间小的手机选 500 MB）→ 点「开始导出」。规划只摸元数据（全库快扫，秒级、不碰逐资产资源调用），拷贝期按实际落盘字节收批：写满预算档位即停；扫描进度实时显示「已扫 x / 32487」，扫描和拷贝全程都可取消。
2. **电脑**：`python pc/pull.py --dest D:\相册导出` —— 必须全 PASS（退出码 0）。
3. **回 App 导出页**：点「清理已拉取文件」→ 确认弹窗 → 手机端删除这批文件、释放空间；清单改记 **PULLED**（哈希保留，无损证明链不断）。
4. 再点「再次导出（增量续跑）」→ 自动接着上一批继续，重名文件不会重导也不会顶名。

状态语义：`OK` = 在手机待拉取；`PULLED` = 已拉取到电脑、手机端已清理（电脑为唯一副本）；`FAIL` = 失败待重试。

两条红线：**清理前必须确认电脑端校验全 PASS**——PULLED 之后手机端不再有这份文件；**拉取目录固定用同一个 `--dest`**（续跑、复验、分批累计都靠它）。空间实在告急时导出会自己踩刹车：剩余空间低于「本文件 + 1 GB 护栏」就优雅结束本批并提示先拉取清理。

## 构建（GitHub Actions → 未签名 IPA → Sideloadly）

与 U盘医生/MyFood 相同的流水线：推送到 `master` 后 Actions 在 macOS 上完成

1. PC 端 unittest（manifest 解析/校验/仅存储 ZIP，纯标准库）
2. `xcodegen generate` 生成 Xcode 工程（工程文件不入库，由 `ios/App/project.yml` 描述）
3. `xcodebuild CODE_SIGNING_ALLOWED=NO` 构建**未签名设备 IPA**
4. `swiftc` 编译并运行核心隔离回归（`ExportPlanner`/`FileHasher`/`ManifestStore`/`TestSupport` + `tests/CoreTests.swift`）
5. 构建 Debug 模拟器包，注入两张 fixture 照片 + 相册授权，`-autoSmoke` 四页巡访截图（含真实小导出）、`-autoTest` 应用内自测
6. 上传 artifact 并把 IPA 发布到 Release

安装：

1. 到仓库 Releases 下载 `photo-export-unsigned.ipa`
2. Windows 上用 [Sideloadly](https://sideloadly.io)（或 AltStore）+ Apple ID 重签后安装到手机

## PC 端：三条拉取路径

App 已开启 iTunes 文件共享（`UIFileSharingEnabled`），原片都在沙盒 `Documents/` 下。

### 方式 A：数据线脚本（推荐）

```sh
pip install -r pc/requirements.txt
python pc/pull.py --list                      # 确认设备已连（需装 iTunes 或「Apple 设备」App 的驱动）
python pc/pull.py --dest D:\相册导出          # 拉取 + 逐文件哈希校验，写 export-report-*.csv
python pc/pull.py --dest D:\相册导出 --zip    # 全 PASS 后顺手打仅存储 ZIP
```

- 中断（拔线/断电）后**重跑同一条命令即续跑**，已验证文件自动跳过；`--fast-resume` 连哈希都不重算（快，但少一道证明）
- 手机上要先跑过一次导出，`Documents/manifest.csv` 存在才能拉

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

- `run_simulator_tests.sh <udid> <smoke|autotest>`：App 用 `-autoSmoke`/`-autoTest` 启动，通过 `tmp/<mode>/now-*`、`ack-*`、`done.txt`、`result.txt` 与 runner 握手（页面截图、断言结果、要求进程正常退出）。smoke 含真实小导出，轮询窗口默认 720 秒（`PE_POLL_SECONDS` 可缩）。
- `test_simulator_runner.sh`：用 mock `xcrun` 验证 runner 的 7 种场景（通过/提前退出/崩溃/失败/超时/缺截图/缺握手），可在无 Mac 环境运行。
- `make_fixtures.py`：纯标准库生成两张小 PNG，CI 用 `simctl addmedia` 注入模拟器相册，让 smoke 巡访跑的是真实导出链路。

## 真机验收清单

1. Sideloadly 装好后打开 App，允许相册访问
2. 先拿 10 张小图试导出 → 记录页全 OK
3. 数据线连电脑，`python pc/pull.py --dest D:\试导出` → 全 PASS
4. 抽 1 张人工抽查：`certutil -hashfile 文件 SHA256` 与 manifest.csv 里那行一致
5. `--zip` 后微信把 zip 发给自己，PC 解压再 `verify.py` 通过
6. 全量大库：用「每批导出上限」分批走 导出 → 拉取全 PASS → 清理 的循环（见上文「大相册：分批导出」）；锁屏前留在导出页（App 会保持常亮），中途断开的话重跑 pull.py 即续跑
