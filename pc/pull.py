# -*- coding: utf-8 -*-
"""pull.py：数据线（usbmuxd/AFC/house_arrest）从 App 沙盒 Documents 拉取原片到电脑，
并逐文件用 SHA-256 与 manifest.csv 比对，出 export-report.csv（固定名，每次覆盖）；--zip 顺带打仅存储包。

依赖：
  pip install pymobiledevice3
Windows 驱动：装 iTunes 或「Apple 设备」App（提供 usbmuxd/Apple Mobile Device Service）。

用法：
  python pc/pull.py --list
  python pc/pull.py --dest D:\\相册导出
  python pc/pull.py --dest D:\\相册导出 --zip
  python pc/pull.py --dest D:\\相册导出 --udid <serial> --fast-resume
"""
from __future__ import annotations

import argparse
import asyncio
import sys
import time
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pe_common  # noqa: E402

DEFAULT_BUNDLE = "com.tokeiyo929.photoexport"

# 上次解析成功的完整 bundle id 缓存（与脚本同目录）：枚举服务再抽风也能续命
CACHE_NAME = ".resolved-app.txt"


def cache_path() -> Path:
    return Path(__file__).resolve().parent / CACHE_NAME


def read_cache() -> str:
    try:
        return cache_path().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def write_cache(bundle: str) -> None:
    try:
        cache_path().write_text(bundle + "\n", encoding="utf-8")
    except OSError:
        pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="数据线拉取 App 导出的原片并校验哈希")
    parser.add_argument("--list", action="store_true", help="列出已连接设备")
    parser.add_argument("--udid", help="设备 serial（多台时用 --list 查看）")
    parser.add_argument("--wifi", nargs="?", const="discover", metavar="URL",
                        help="WiFi 直传：不带值=Bonjour 自动搜索同一网络里的手机 App（推荐）；"
                             "也可手填 App 首页显示的地址（如 http://192.168.1.5:8765）。"
                             "台式机没网卡时：手机开个人热点+数据线连电脑，用 App 列出的 172.20.10.x 地址")
    parser.add_argument("--app", default=DEFAULT_BUNDLE, help=f"App bundle id（默认 {DEFAULT_BUNDLE}）")
    parser.add_argument("--dest", help="拉取目标目录")
    parser.add_argument("--zip", action="store_true", help="校验通过后打仅存储 ZIP")
    parser.add_argument("--fast-resume", action="store_true",
                        help="续跑时同大小文件不重算哈希（快，但少一道证明）")
    parser.add_argument("--compare-orphans", action="store_true",
                        help="原图对照：把清单外文件（你在相册用系统「导出未修改的原片」"
                             "分享进本 App 的）也拉到 _原图对照/ 并与清单哈希逐个比对")
    parser.add_argument("--coredevice", action="store_true",
                        help="强制走 CoreDevice FileService 通道（Xcode 同款，绕开 house_arrest；"
                             "iOS 17+ Windows 免 root 用户态隧道）。house_arrest 读不到清单时"
                             "也会自动切到本通道，一般无需手动指定")
    return parser.parse_args()


async def list_devices() -> int:
    try:
        from pymobiledevice3 import usbmux
        from pymobiledevice3.lockdown import create_using_usbmux
    except ImportError:
        pe_common.log("缺少依赖：pip install pymobiledevice3")
        return 2
    devices = await usbmux.list_devices()  # v11+ 全线 async API
    if not devices:
        pe_common.log("未发现设备：插数据线、解锁手机、信任电脑；Windows 需装 iTunes/Apple 设备 App 的驱动。")
        return 1
    for device in devices:
        try:
            lockdown = await create_using_usbmux(serial=device.serial)
            info = lockdown.short_info
            pe_common.log(f"serial={device.serial}  名称={info.get('DeviceName', '?')}  "
                          f"系统={info.get('ProductVersion', '?')}  型号={info.get('ProductType', '?')}")
            await lockdown.close()
        except Exception as error:  # 设备可能锁着配对
            pe_common.log(f"serial={device.serial}  （读取信息失败：{error}）")
    return 0


# MARK: WiFi 直传模式（App 内置局域网 HTTP 服务）。
# 背景：iOS 27 上数据线 AFC 通道对本 App 服务了错误的容器视图（按名读永远
# OBJECT_NOT_FOUND）；WiFi 拉取（LocalSend 同款模式）是可靠通道。台式机没无线
# 网卡时走「手机个人热点 + 数据线」的 USB 网卡（172.20.10.x），一根线全搞定。


def _http_get(url: str, timeout: int = 30) -> bytes:
    import urllib.request
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as response:
                return response.read()
        except Exception as error:  # 连接抖动重试（与 AFC 同样待遇）
            last_error = error
            if attempt < 2:
                time.sleep(1.5)
    assert last_error is not None
    raise last_error


def _http_download(url: str, target: Path, timeout: int = 60) -> bool:
    """流式下载到 <target>.part 再原子改名：中断不产生半截假文件。
    有遗留 .part 就带 Range 头续传（成熟文件服务器 GCDWebServer 同款）；
    服务器回 200 不认 Range 就整个重下。返回是否发生了续传。"""
    import shutil
    import urllib.error
    import urllib.request
    part = target.with_name(target.name + ".part")
    resumed = False
    for attempt in range(2):
        headers: dict[str, str] = {}
        resumed = attempt == 0 and part.exists() and part.stat().st_size > 0
        if resumed:
            headers["Range"] = f"bytes={part.stat().st_size}-"
        try:
            request = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                status = getattr(response, "status", 200)
                if status == 206 and resumed:
                    with open(part, "ab") as handle:  # 从断点接着写
                        shutil.copyfileobj(response, handle, length=1024 * 1024)
                else:
                    resumed = False
                    with open(part, "wb") as handle:  # 服务器不支持 Range，从头来
                        shutil.copyfileobj(response, handle, length=1024 * 1024)
            break
        except urllib.error.HTTPError as error:
            if error.code == 416 and attempt == 0 and part.exists():
                part.unlink()  # 断点越界（服务器端文件变了）→ 清掉重来
                continue
            raise
    part.replace(target)
    return resumed


def _wifi_discover(timeout_seconds: float = 10.0) -> str:
    """Bonjour 自动发现 App 的 WiFi 服务（_photoexport._tcp.），返回 base URL。
    成熟工具（LocalSend/GCDWebServer）同款思路：手机广播，电脑浏览，免手打 IP。
    找到一台→直接用；多台/零台→打日志提示手打地址。"""
    import socket
    import time
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        pe_common.log("自动发现缺依赖：pip install zeroconf（或手打 --wifi http://IP:8765）")
        return ""
    found: dict[str, str] = {}

    class _Listener:
        def add_service(self, zc, type_, name):
            info = zc.get_service_info(type_, name, timeout=3000)
            if info and info.addresses:
                ip = socket.inet_ntoa(info.addresses[0])
                found[name] = f"http://{ip}:{info.port}"

        def update_service(self, *args):
            pass

        def remove_service(self, *args):
            pass

    pe_common.log(f"正在自动搜索同一网络里的手机 App（Bonjour _photoexport._tcp.，最多 {int(timeout_seconds)} 秒）…")
    zc = Zeroconf()
    try:
        ServiceBrowser(zc, "_photoexport._tcp.", _Listener())
        deadline = time.time() + timeout_seconds
        while time.time() < deadline and not found:
            time.sleep(0.3)
        time.sleep(1.0)  # 再攒一秒，多台手机时能凑齐
    finally:
        zc.close()
    if not found:
        pe_common.log("没搜到。检查：①App 首页已点「开启 WiFi 传图」②手机和电脑同一网络"
                      "（部分路由器隔离组播，那就手打 --wifi http://IP:8765）")
        return ""
    if len(found) > 1:
        pe_common.log("搜到多台，请手打对应地址：")
        for name, url in sorted(found.items()):
            pe_common.log(f"  {name} -> {url}")
        return ""
    url = next(iter(found.values()))
    pe_common.log(f"已发现手机：{url}")
    return url


def index_by_basename(rows) -> dict:
    """清单行按文件名（basename）索引；同名多行（跨年份重名/实况视频对）保留全部。"""
    index: dict[str, list] = {}
    for r in rows:
        index.setdefault(Path(r.relative_path).name, []).append(r)
    return index


def compare_baseline_rows(listing_kind: str, rows, report: list) -> list:
    """原图对照的哈希基线行。manifest 模式用手机端哈希；
    index 模式（v4 无手机端基线）用本次拉取现算留档的哈希（PASS/SKIP-VERIFIED 行）。"""
    if listing_kind == "manifest":
        return pe_common.last_wins(rows)
    return [pe_common.ManifestRow(relative_path=r["relative_path"], sha256=r["actual_sha256"])
            for r in report if r["result"] in ("PASS", "SKIP-VERIFIED")]


def short_afc_error(error: Exception) -> str:
    """AFC 错误缩写：抽出「(AFC status XXX)」段，便于逐路径罗列比对。"""
    text = str(error)
    marker = "(AFC status "
    if marker in text:
        return text[text.index(marker) + 1:].rstrip(")")
    return text[-80:]


def wifi_pull(args: argparse.Namespace) -> int:
    base = (args.wifi or "").strip()
    if not base or base.lower() in ("discover", "auto"):
        base = _wifi_discover()
        if not base:
            return 2
    base = base.rstrip("/")
    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)
    pe_common.log(f"WiFi 直传：{base}")

    # 1) 清单
    try:
        manifest_bytes = _http_get(base + "/manifest.csv")
    except Exception as error:
        pe_common.log(f"拉取 manifest.csv 失败：{error}")
        pe_common.log("确认：①App 首页已点「开启 WiFi 传图」②地址与 App 显示一致 ③手机和电脑同一网络"
                      "（台式机可用手机个人热点+数据线的 172.20.10.x 地址）")
        return 2
    rows, malformed = pe_common.parse_manifest_bytes(manifest_bytes)
    # 清单落盘到 --dest：无损证明链的根（verify.py 复验、查某张照片的哈希都靠它）
    (dest / pe_common.MANIFEST_NAME).write_bytes(manifest_bytes)
    expected = pe_common.pullable_rows(rows)
    pulled_note = ""
    if any(r.status == "PULLED" for r in pe_common.last_wins(rows)):
        pulled_note = "（PULLED 的已拉取清理，跳过）"
    pe_common.log(f"清单：待拉取 {len(expected)} 个文件{pulled_note}"
                  + (f"，损坏行 {malformed}" if malformed else ""))

    # 2) 诊断日志顺带拉回（不参与校验）：App 收缩后日志归 logs/，兼容旧版根目录
    for diag in ("logs/export-log.txt", "logs/export-log.old.txt",
                 "export-log.txt", "export-log.old.txt"):
        try:
            data = _http_get(base + "/" + diag)
        except Exception:
            continue
        target = dest / f"device-{diag}"
        target.write_bytes(data)
        pe_common.log(f"已拉回诊断日志：{target}（{pe_common.bytes_str(len(data))}）")

    # 3) 逐文件拉取 + 校验（续跑语义与数据线模式一致）
    report: list[dict] = []
    summary = pe_common.VerifySummary()
    done = 0
    for row in expected:
        done += 1
        rel = row.relative_path
        target = pe_common.local_path(dest, rel)
        prefix = f"[{done}/{len(expected)}]"
        # 续跑：本地已有且大小一致（--fast-resume 直接认；默认再验哈希）
        if target.exists() and target.stat().st_size == row.size:
            if args.fast_resume:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, row.sha256, "(fast-resume)", row.size,
                                                    "SKIP-VERIFIED", "同大小，未重算哈希"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
            if pe_common.sha256_file(target) == row.sha256:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, row.sha256, row.sha256, row.size,
                                                    "SKIP-VERIFIED", "已存在且哈希一致"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
        url = base + "/file/" + urllib.parse.quote(rel)
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            resumed = _http_download(url, target)
        except Exception as error:
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, "", 0, "ERROR", f"WiFi 拉取失败：{error}"))
            pe_common.log(f"{prefix} ERROR {rel} —— {error}")
            continue
        actual_sha = pe_common.sha256_file(target)
        actual_size = target.stat().st_size
        if actual_size != row.size or actual_sha != row.sha256:
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, actual_sha, actual_size, "FAIL",
                                                "拉取后哈希不一致"))
            pe_common.log(f"{prefix} FAIL  {rel}")
        else:
            summary.passed += 1
            summary.total_bytes += actual_size
            report.append(pe_common._report_row(rel, row.sha256, actual_sha, actual_size, "PASS",
                                                "断点续传" if resumed else ""))
            pe_common.log(f"{prefix} PASS  {rel}  ({pe_common.bytes_str(actual_size)})"
                          + ("  [续传]" if resumed else ""))

    # 4) 报告与总结
    report_path = pe_common.default_report_path(dest)
    pe_common.write_report(report, report_path)
    pe_common.log(f"报告：{report_path}")
    pe_common.log(f"结果：PASS {summary.passed} · 已验证跳过 {summary.skipped_verified} · "
                  f"FAIL {summary.failed} · 总量 {pe_common.bytes_str(summary.total_bytes)}")

    # 5) 护甲 ZIP
    if args.zip:
        if summary.failed:
            pe_common.log("有 FAIL 项，跳过打包（先解决失败再 --zip）。")
        else:
            zip_path = dest.parent / f"照片导出-{pe_common.stamp()}.zip"
            count, zipped = pe_common.make_store_zip(dest, zip_path)
            pe_common.log(f"仅存储 ZIP：{zip_path}（{count} 个文件，{pe_common.bytes_str(zipped)}，字节未动）")
    return 0 if summary.ok else 1


async def coredevice_amain(args: argparse.Namespace) -> int:
    """CoreDevice FileService 通道（iOS 17+，Xcode/开发者工具同款）：走 RSD 加密隧道 +
    dtfileserviced，**完全绕开 house_arrest**——house_arrest 读到过期容器视图时这是生态正路
    （调研实锤：pymobiledevice3 remote/core_device/file_service.py，Windows 免 root 用户态隧道）。
    注意：appDataContainer 域=整个数据容器（路径相对容器根，等价 VendContainer 视图）；
    文件整读进内存（分块 512KB 累加），照片/视频量级可接受。"""
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.remote.core_device.file_service import Domain, FileServiceService
    from pymobiledevice3.remote.userspace_tunnel import UserspaceRsdTunnel
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    # 解析重签后缀 bundle id（与 house_arrest 通道同一套逻辑：精确→前缀→缓存）
    bundle = args.app
    last_error: Exception | None = None
    pe_common.log("枚举已装 App（解析重签后缀）…")
    for attempt in range(5):
        try:
            enum_lockdown = await create_using_usbmux(serial=args.udid)
            try:
                installed = await InstallationProxyService(enum_lockdown).get_apps()
            finally:
                await enum_lockdown.close()
            if bundle in installed:
                break
            candidates = sorted(b for b in installed
                                if b == args.app or b.startswith(args.app + "."))
            if len(candidates) == 1:
                bundle = candidates[0]
                pe_common.log(f"App 已重签名，实际 bundle id：{bundle}")
            elif len(candidates) > 1:
                pe_common.log("找到多个匹配的 App，请用 --app 指定其一：")
                for b in candidates:
                    pe_common.log(f"  {b}")
                return 2
            break
        except Exception as error:
            last_error = error
            if attempt < 4:
                await asyncio.sleep(2)
    else:
        cached = read_cache()
        if cached:
            bundle = cached
            pe_common.log(f"枚举失败（{last_error}），用缓存 App id：{bundle}")
        else:
            pe_common.log(f"枚举失败（{last_error}），按原名尝试。")

    tunnel = UserspaceRsdTunnel(serial=args.udid)
    pe_common.log("建立 CoreDevice 用户态隧道（iOS 17+ 免 root，首次要几秒）…")
    rsd = await tunnel.aopen()
    try:
        pe_common.log(f"隧道已建立（udid={rsd.udid}）。打开 App 数据容器（dtfileserviced）：{bundle}")
        async with FileServiceService(rsd, Domain.APP_DATA_CONTAINER, bundle) as fs:
            return await _coredevice_pull(args, fs, dest, bundle)
    finally:
        try:
            await rsd.close()
        except Exception:
            pass
        await tunnel.aclose()


async def _coredevice_pull(args: argparse.Namespace, fs, dest: Path, bundle: str) -> int:
    APP_SUPPORT = "Library/Application Support/PhotoExport"

    async def pull_diag_logs(bases: list[str]) -> None:
        cands: list[tuple[str, str]] = []
        for b in bases:
            for n in ("logs/export-log.txt", "logs/export-log.old.txt",
                      "export-log.txt", "export-log.old.txt"):
                p = "/".join(x for x in [b, n] if x)
                btag = "" if b == APP_SUPPORT else "-docroot"
                ltag = "" if n.startswith("logs/") else "-rootfile"
                name = f"device-{Path(n).stem}{ltag}{btag}.txt"
                if not any(c[1] == name for c in cands):
                    cands.append((p, name))
        for diag, name in cands:
            try:
                data = await fs.get_file_contents(diag)
            except Exception:
                continue
            target = dest / name
            target.write_bytes(data)
            pe_common.log(f"已拉回诊断日志：{diag} → {target}（{pe_common.bytes_str(len(data))}）")

    # 清单发现：容器根视角，App Support 优先（v3+/v4），Documents 根兜底（旧布局）
    listing_bytes: bytes | None = None
    listing_kind = ""
    base = ""
    for kind, name in [("index", pe_common.INDEX_NAME), ("manifest", pe_common.MANIFEST_NAME)]:
        for cand_base in (APP_SUPPORT, "", "Documents"):
            path = "/".join(x for x in [cand_base, name] if x)
            try:
                listing_bytes = await fs.get_file_contents(path)
                listing_kind = kind
                base = cand_base
                pe_common.log(f"CoreDevice 命中 {kind}：{path}")
                break
            except Exception:
                continue
        if listing_bytes is not None:
            break
    if listing_bytes is None:
        pe_common.log("CoreDevice 通道也读不到 index.txt / manifest.csv。")
        pe_common.log("= 数据容器里真没有清单文件：App 还没打开过/没导入过（App 自己能看到就截图反馈）。")
        await pull_diag_logs([APP_SUPPORT, "", "Documents"])
        return 2

    def rooted(rel: str) -> str:
        return "/".join(x for x in [base, rel] if x)

    await pull_diag_logs([base] if base else [""])
    malformed = 0
    pulled_note = ""
    if listing_kind == "manifest":
        rows, malformed = pe_common.parse_manifest_bytes(listing_bytes)
        (dest / pe_common.MANIFEST_NAME).write_bytes(listing_bytes)
        expected = pe_common.pullable_rows(rows)
        if any(r.status == "PULLED" for r in pe_common.last_wins(rows)):
            pulled_note = "（PULLED 的已拉取清理，跳过）"
        pe_common.log(f"清单：待拉取 {len(expected)} 个文件{pulled_note}"
                      + (f"，损坏行 {malformed}" if malformed else ""))
    else:
        rows = []
        expected = pe_common.rows_from_index(listing_bytes)
        (dest / "index.txt").write_bytes(listing_bytes)
        pe_common.log(f"暂存区清单（index.txt，v4 传送带）：待拉取 {len(expected)} 个文件（哈希现算留档）")

    # 逐文件拉取 + 校验（语义与 house_arrest 通道一致；设备端大小用 get_attributes 对账）
    report: list[dict] = []
    summary = pe_common.VerifySummary()
    done = 0
    for row in expected:
        done += 1
        rel = row.relative_path
        target = pe_common.local_path(dest, rel)
        prefix = f"[{done}/{len(expected)}]"
        device_size = 0
        try:
            attrs = await fs.get_attributes(rooted(rel))
            device_size = int(attrs.get("size", 0))
        except Exception:
            pass  # 属性拿不到不拦路：拉取时以实际内容为准
        if target.exists() and target.stat().st_size == row.size and (not device_size or device_size == row.size):
            dest_sha = pe_common.sha256_file(target)
            if not row.sha256:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, dest_sha, dest_sha, row.size,
                                                    "SKIP-VERIFIED", "同大小（无手机端哈希基线）"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
            if args.fast_resume:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, row.sha256, "(fast-resume)", row.size,
                                                    "SKIP-VERIFIED", "同大小，未重算哈希"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
            if dest_sha == row.sha256:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, row.sha256, dest_sha, row.size,
                                                    "SKIP-VERIFIED", "已存在且哈希一致"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            data = await fs.get_file_contents(rooted(rel))
        except Exception as error:
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, "", 0, "ERROR", f"CoreDevice 拉取失败：{error}"))
            pe_common.log(f"{prefix} ERROR {rel} —— {error}")
            continue
        target.write_bytes(data)
        del data
        actual_sha = pe_common.sha256_file(target)
        actual_size = target.stat().st_size
        if actual_size != row.size or (row.sha256 and actual_sha != row.sha256):
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, actual_sha, actual_size, "FAIL",
                                                "拉取后大小/哈希不一致"))
            pe_common.log(f"{prefix} FAIL  {rel}")
        else:
            summary.passed += 1
            summary.total_bytes += actual_size
            report.append(pe_common._report_row(rel, row.sha256 or actual_sha, actual_sha, actual_size, "PASS", ""))
            pe_common.log(f"{prefix} PASS  {rel}  ({pe_common.bytes_str(actual_size)})")

    report_path = pe_common.default_report_path(dest)
    pe_common.write_report(report, report_path)
    pe_common.log(f"报告：{report_path}")
    pe_common.log(f"结果：PASS {summary.passed} · 已验证跳过 {summary.skipped_verified} · "
                  f"FAIL {summary.failed} · 总量 {pe_common.bytes_str(summary.total_bytes)}")
    if args.compare_orphans:
        pe_common.log("（--compare-orphans 在 CoreDevice 通道暂不可用——数据线 house_arrest 恢复后再对照）")
    if args.zip:
        if summary.failed:
            pe_common.log("有 FAIL 项，跳过打包（先解决失败再 --zip）。")
        else:
            zip_path = dest.parent / f"照片导出-{pe_common.stamp()}.zip"
            count, zipped = pe_common.make_store_zip(dest, zip_path)
            pe_common.log(f"仅存储 ZIP：{zip_path}（{count} 个文件，{pe_common.bytes_str(zipped)}，字节未动）")
    return 0 if summary.ok else 1


async def amain(args: argparse.Namespace) -> int:
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    from pymobiledevice3.services.installation_proxy import InstallationProxyService

    dest = Path(args.dest)
    dest.mkdir(parents=True, exist_ok=True)

    pe_common.log(f"连接设备（{args.udid or '第一台'}）…")
    lockdown = await create_using_usbmux(serial=args.udid)
    pe_common.log(f"已连接：{lockdown.short_info.get('DeviceName', '?')} "
                  f"iOS {lockdown.short_info.get('ProductVersion', '?')}")
    pe_common.log("枚举已装 App（解析重签后缀，个别系统这步要几秒）…")

    # 解析实际 bundle id：Sideloadly 免签重签会在原 id 后追加团队后缀
    # （如 com.tokeiyo929.photoexport.FBTKZ8C6QB），先精确匹配再前缀匹配。
    # 枚举连接常被系统掐断（Connection was terminated abruptly）：
    # 每次尝试新建独立 lockdown 会话（被掐过的旧会话可能已坏），共 5 次、间隔 2s；
    # 全失败则退回上次解析成功的缓存 id（.resolved-app.txt，与脚本同目录）。
    bundle = args.app
    installed = None
    last_error: Exception | None = None
    for attempt in range(5):
        try:
            enum_lockdown = await create_using_usbmux(serial=args.udid)
            try:
                installed = await InstallationProxyService(enum_lockdown).get_apps()
            finally:
                await enum_lockdown.close()
            break
        except Exception as error:
            last_error = error
            if attempt < 4:
                await asyncio.sleep(2)
    if installed is None:
        cached = read_cache()
        if cached:
            pe_common.log(f"枚举已装 App 失败（重试 5 次均失败），改用上次解析成功的缓存 App id：{cached}")
            pe_common.log(f"（枚举错误：{last_error}）")
            bundle = cached
        else:
            pe_common.log(f"枚举已装 App 失败（重试 5 次均失败，按原名尝试）：{last_error}")
    elif bundle not in installed:
        candidates = sorted(b for b in installed
                            if b == args.app or b.startswith(args.app + "."))
        if len(candidates) == 1:
            bundle = candidates[0]
            pe_common.log(f"App 已重签名，实际 bundle id：{bundle}")
        elif len(candidates) > 1:
            pe_common.log("找到多个匹配的 App，请用 --app 指定其一：")
            for b in candidates:
                pe_common.log(f"  {b}")
            return 2
    if installed is not None and bundle != args.app:
        write_cache(bundle)

    pe_common.log(f"打开 App 沙盒（house_arrest）：{bundle}")
    # create 工厂 = 构造 + await send_command(VendDocuments)，出错自动关闭
    try:
        house = await HouseArrestService.create(lockdown, bundle, documents_only=True)
    except Exception:
        if bundle != args.app:
            # 缓存的后缀可能已过期（换签名团队重装后缀会变）：清掉让下次重新枚举
            cache_path().unlink(missing_ok=True)
            pe_common.log(f"用 {bundle} 打不开沙盒，已清缓存（重跑本命令会重新枚举）。")
        raise

    # iOS 27 实锤：对重签名 App，house_arrest 可能服务错误的容器视图（按名读全 OBJECT_NOT_FOUND，
    # App 自己却读写正常）。house_arrest 协议客户端只有 VendDocuments/VendContainer 两个旋钮
    # （读 pymobiledevice3 源码实锤，没有「指定容器」参数），成熟工具（ifuse --documents/iMazing）
    # 也都只有这条路。
    # v3 布局（2026-11-17）：App 内部文件住 Library/Application Support/PhotoExport（文件 App
    # 不可见），旧布局住 Documents 根。VendDocuments 只够得着 Documents（旧布局）；
    # VendContainer 整容器两种都行——所以先 VendDocuments，不行退 VendContainer 挨个试。
    # v4 传送带：手机端没有账本，枚举靠 App 实测重建的 index.txt（size\t相对路径，按名读
    # 不受「列目录 PERM_DENIED」限制）；旧版手机仍在的话退回 manifest.csv（哈希校验更全）。
    APP_SUPPORT = "Library/Application Support/PhotoExport"
    offset = ""        # AFC 根偏移：VendDocuments 根就是 Documents；VendContainer 根是容器
    base = ""          # App 内部文件区前缀：旧布局 Documents 根（""），v3+ 布局 App Support
    listing_bytes: bytes | None = None
    listing_kind = ""  # "index"（v4）或 "manifest"（旧版）
    last_error: Exception | None = None
    attempts: list[tuple[str, str]] = []   # (AFC 路径, 短错误) 全记录，失败时逐条打印

    async def pull_diag_logs(bases: list[str]) -> None:
        """诊断日志回捞：清单读不到时也要拿到（真机挂死不留报告，时间线在这里）。
        bases 按优先级给文件区前缀。不同布局的同名文件**必须**落不同名——
        否则 Documents 根的陈年残留会把 App Support 里的当前日志覆盖掉（实锤踩过）。"""
        cands: list[tuple[str, str]] = []   # (AFC 路径, 落盘文件名)
        for b in bases:
            for n in ("logs/export-log.txt", "logs/export-log.old.txt",
                      "export-log.txt", "export-log.old.txt"):
                p = "/".join(x for x in [offset, b, n] if x)
                btag = "" if b == APP_SUPPORT else "-docroot"   # Documents 根的旧版残留
                ltag = "" if n.startswith("logs/") else "-rootfile"
                name = f"device-{Path(n).stem}{ltag}{btag}.txt"
                if not any(c[1] == name for c in cands):
                    cands.append((p, name))
        for diag, name in cands:
            try:
                data = await house.get_file_contents(diag)
            except Exception:
                continue
            target = dest / name
            target.write_bytes(data)
            pe_common.log(f"已拉回诊断日志：{diag} → {target}（{pe_common.bytes_str(len(data))}）")

    # 第一轮 VendDocuments：只够得着 Documents 根（旧布局）
    for kind, name in [("index", pe_common.INDEX_NAME), ("manifest", pe_common.MANIFEST_NAME)]:
        try:
            listing_bytes = await house.get_file_contents(name)
            listing_kind = kind
            base = ""
            break
        except Exception as error:
            last_error = error
            attempts.append((name, short_afc_error(error)))
    if listing_bytes is None:
        pe_common.log(f"VendDocuments 视图读不到 index/manifest：{last_error}")
        pe_common.log("退回 VendContainer（整容器）再试——iOS 27 两种 vend 命令的容器映射可能不同。")
        try:
            await house.close()
        except Exception:
            pass
        house = await HouseArrestService.create(lockdown, bundle, documents_only=False)
        offset = "Documents"
        for kind, name in [("index", pe_common.INDEX_NAME), ("manifest", pe_common.MANIFEST_NAME)]:
            for cand_base, label in [(APP_SUPPORT, "Application Support（v3+/v4 布局）"),
                                     ("", "Documents 根（旧布局）")]:
                parts = [p for p in [offset, cand_base, name] if p]
                try:
                    listing_bytes = await house.get_file_contents("/".join(parts))
                    listing_kind = kind
                    base = cand_base
                    pe_common.log(f"VendContainer 命中 {kind}：{label}——数据线走整容器模式。")
                    break
                except Exception as error2:
                    last_error = error2
                    attempts.append(("/".join(parts), short_afc_error(error2)))
            if listing_bytes is not None:
                break
    if listing_bytes is None:
        pe_common.log("两种 vend 都读不到 index.txt / manifest.csv。各路径实际结果：")
        for path_label, err in attempts:
            pe_common.log(f"  {path_label} → {err}")
        if all("OBJECT_NOT_FOUND" in e for _, e in attempts):
            pe_common.log("= 手机沙盒里既没有 index.txt 也没有 manifest.csv。两种可能：")
            pe_common.log("① 装了新 ipa（重签=新容器，旧数据不跟过来）且还没打开过 App → 先打开 App、导入照片，再拉")
            pe_common.log("② App 打开过、首页也显示「已入暂存」→ 截图首页（顶部构建号+占用卡）反馈")
        else:
            pe_common.log("出现了非 OBJECT_NOT_FOUND 的错误 = AFC 容器视图/权限问题（iOS 27 已知怪癖），截图反馈")
        # 容器指纹：有的设备/通道允许列目录，能列出来就直接看里面有什么
        for dir_path in ["/".join(x for x in [offset, APP_SUPPORT] if x),
                         "/".join(x for x in [offset] if x)]:
            try:
                names = await house.listdir(dir_path)
                shown = sorted(names)[:20]
                more = f"（共 {len(names)} 个，只显示前 20）" if len(names) > 20 else ""
                pe_common.log(f"listdir {dir_path or '/'} → {shown}{more}")
            except Exception as error:
                pe_common.log(f"listdir {dir_path or '/'} → {short_afc_error(error)}")
        await pull_diag_logs([APP_SUPPORT, ""])  # 清单读不到也要回捞日志
        # house_arrest 读不到清单（疑似 iOS 27 过期容器视图）→ 自动换 CoreDevice 通道再试。
        # 调研实锤：Xcode 同款 dtfileserviced，独立重新解析 bundle id，完全绕开 house_arrest。
        pe_common.log("===== 自动切换 CoreDevice FileService 通道（Xcode 同款，绕开 house_arrest）=====")
        try:
            await lockdown.close()
        except Exception:
            pass
        try:
            return await coredevice_amain(args)
        except ImportError as error:
            pe_common.log(f"CoreDevice 通道不可用（pymobiledevice3 太旧，先 pip install -U pymobiledevice3）：{error}")
            return 2
        except Exception as error:
            pe_common.log(f"CoreDevice 通道也失败：{error}")
            pe_common.log("排查：①手机重启后再试（iloader#294 实锤能重置设备侧 vend 缓存）"
                          "②确认手机已解锁且信任了电脑 ③iOS 17.0-17.3 需管理员 tunneld（iOS 27 不需要）")
            return 2

    def rooted(rel: str) -> str:
        """App 内部文件区相对路径 → AFC 会话里的实际路径。"""
        parts = [p for p in [offset, base, rel] if p]
        return "/".join(parts)

    # 诊断日志顺带拉回（不参与校验）：真机闪退常常不留报告，时间线在这里。
    # 优先已发现布局的 logs/，再扫旧版根目录（pull_diag_logs 内部去重）。
    await pull_diag_logs([base, ""] if base else [""])
    malformed = 0
    pulled_note = ""
    if listing_kind == "manifest":
        rows, malformed = pe_common.parse_manifest_bytes(listing_bytes)
        # 清单落盘到 --dest：无损证明链的根（verify.py 复验、查某张照片的哈希都靠它）
        (dest / pe_common.MANIFEST_NAME).write_bytes(listing_bytes)
        expected = pe_common.pullable_rows(rows)
        if any(r.status == "PULLED" for r in pe_common.last_wins(rows)):
            pulled_note = "（PULLED 的已拉取清理，跳过）"
        pe_common.log(f"清单：待拉取 {len(expected)} 个文件{pulled_note}"
                      + (f"，损坏行 {malformed}" if malformed else ""))
    else:
        rows = []  # index 模式无手机端哈希行；对照基线改用拉取时现算的哈希
        expected = pe_common.rows_from_index(listing_bytes)
        (dest / "index.txt").write_bytes(listing_bytes)
        pe_common.log(f"暂存区清单（index.txt，v4 传送带）：待拉取 {len(expected)} 个文件（哈希拉取时在电脑端现算）")

    # 2) 枚举设备端文件（顺带发现清单之外的孤儿文件）
    # iOS 27 真机实测：AFC 对第三方沙盒「按名读可以，列目录 PERM_DENIED」，
    # 列不了就跳过孤儿检测，别让整个拉取炸掉。
    # v3 布局要逛两棵树：App 内部区（键剥掉 offset+base，对齐清单相对路径）
    # 和 Documents（键剥 offset，用户存的对照照片/未登记文件以「导入/…」出现）。
    device_files: dict[str, int] = {}

    async def walk_dir(prefix: str, strips: list) -> None:
        for name in await house.listdir(prefix or "/"):
            if name.startswith("."):
                continue
            path = f"{prefix}/{name}".replace("//", "/")
            if await house.isdir(path):
                await walk_dir(path, strips)
            else:
                stat = await house.stat(path)
                key = path.lstrip("/")
                for pref in strips:
                    if pref and key.startswith(pref + "/"):
                        key = key[len(pref) + 1:]
                device_files[key] = stat.get("st_size", 0)

    walk_roots: list[tuple[str, list]] = [(rooted(""), [offset, base] if base else ([offset] if offset else []))]
    docs_root = "Documents" if offset == "Documents" else ""
    if docs_root and docs_root != rooted(""):
        # 旧布局时 rooted("") 就是 Documents，不重复逛；v3 布局下 Documents 另逛一遍
        walk_roots.append((docs_root, [offset] if offset else []))
    try:
        for root_path, strips in walk_roots:
            await walk_dir(root_path, strips)
    except Exception as error:
        pe_common.log(f"设备端文件枚举失败（跳过孤儿检测）：{error}")
    known = {r.relative_path for r in expected}
    # 孤儿=清单外文件。诊断日志与 index/manifest 本身是内部文件，不算孤儿
    # （键已剥掉 offset/base 前缀，与上面 diag 落 dest 的 device-* 文件一一对应）。
    diag_rels = {"logs/export-log.txt", "logs/export-log.old.txt",
                 "export-log.txt", "export-log.old.txt"}
    internal_names = diag_rels | {pe_common.MANIFEST_NAME, pe_common.INDEX_NAME}
    orphans = [p for p in device_files if p not in known and p not in internal_names]
    if orphans and not args.compare_orphans:
        pe_common.log(f"警告：设备上有 {len(orphans)} 个清单外文件（可能是上次失败残留），已跳过不拉。")

    # 3) 逐文件拉取 + 校验
    report: list[dict] = []
    summary = pe_common.VerifySummary()
    done = 0
    for row in expected:
        done += 1
        rel = row.relative_path
        target = pe_common.local_path(dest, rel)
        prefix = f"[{done}/{len(expected)}]"
        # 续跑：本地已有且大小一致（--fast-resume 直接认；默认再验哈希）
        if target.exists() and target.stat().st_size == row.size:
            dest_sha = pe_common.sha256_file(target)
            if not row.sha256:
                # index 模式没有手机端哈希基线：同大小即认，PC 端哈希照样入报告留档
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, dest_sha, dest_sha, row.size,
                                                    "SKIP-VERIFIED", "同大小（无手机端哈希基线）"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
            if args.fast_resume:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, row.sha256, "(fast-resume)", row.size,
                                                    "SKIP-VERIFIED", "同大小，未重算哈希"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
            if dest_sha == row.sha256:
                summary.skipped_verified += 1
                summary.total_bytes += row.size
                report.append(pe_common._report_row(rel, row.sha256, dest_sha, row.size,
                                                    "SKIP-VERIFIED", "已存在且哈希一致"))
                pe_common.log(f"{prefix} SKIP  {rel}")
                continue
        # 拉取（App 端按日期归档的相对路径；pull 保留 basename，落位不变）
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            await house.pull(rooted(rel), str(target.parent))
        except Exception as error:
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, "", 0, "ERROR", f"拉取失败：{error}"))
            pe_common.log(f"{prefix} ERROR {rel} —— {error}")
            continue
        actual_sha = pe_common.sha256_file(target)
        actual_size = target.stat().st_size
        if actual_size != row.size or (row.sha256 and actual_sha != row.sha256):
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, actual_sha, actual_size, "FAIL",
                                                "拉取后大小/哈希不一致"))
            pe_common.log(f"{prefix} FAIL  {rel}")
        else:
            summary.passed += 1
            summary.total_bytes += actual_size
            # index 模式没有手机端基线：以电脑端现算哈希为准记录在案（后续重拉可比对）
            report.append(pe_common._report_row(rel, row.sha256 or actual_sha, actual_sha, actual_size, "PASS", ""))
            pe_common.log(f"{prefix} PASS  {rel}  ({pe_common.bytes_str(actual_size)})")

    # 3.5) 原图对照（独立裁判）：用户在相册 App 用系统自带「导出未修改的原片」分享到
    # 本 App（文件会落进沙盒 Documents），这些文件对清单而言是「清单外文件」。
    # 拉回来按文件名对清单哈希逐个比对——系统 UI 导出 vs 我们的 PHAssetResource 直出，
    # 字节一致 = 真原图实锤（相册那个菜单背后就是同一个原始资源 API，但空口无凭，对出证据来）。
    if args.compare_orphans and orphans:
        compare_dir = dest / "_原图对照"
        compare_dir.mkdir(exist_ok=True)
        pe_common.log(f"原图对照：拉取 {len(orphans)} 个清单外文件（系统导出的原片）…")
        existing = [(p.name, p.stat().st_size) for p in compare_dir.rglob("*") if p.is_file()]
        for rel in orphans:
            base = Path(rel).name
            # 之前对照拉过同名同大小的就跳过（对照目录不越积越多）
            if (base, device_files.get(rel, 0)) in existing:
                pe_common.log(f"[对照] {base} 已在对照目录里，跳过拉取")
                continue
            sub = compare_dir
            # 同名落位冲突就进序号子目录，别覆盖
            n = 1
            while (sub / base).exists():
                n += 1
                sub = compare_dir / str(n)
            sub.mkdir(parents=True, exist_ok=True)
            try:
                await house.pull(rooted(rel), str(sub))
            except Exception as error:
                pe_common.log(f"[对照] {base} 拉取失败：{error}")
        # 对照：basename 匹配基线行 → 哈希比对（manifest 含 PULLED/FAIL 行——对照不限状态）
        by_base = index_by_basename(compare_baseline_rows(listing_kind, rows, report))
        verified = mismatched = unmatched = 0
        for path in sorted(compare_dir.rglob("*")):
            if not path.is_file():
                continue
            matches = by_base.get(path.name, [])
            if not matches:
                unmatched += 1
                pe_common.log(f"[对照] {path.name} —— 清单里没有同名文件，跳过")
                continue
            actual = pe_common.sha256_file(path)
            hit = next((r for r in matches if r.sha256 == actual), None)
            if hit:
                verified += 1
                pe_common.log(f"[对照] {path.name} ↔ {hit.relative_path}  PASS（字节一致，真原图实锤）")
            else:
                mismatched += 1
                pe_common.log(f"[对照] {path.name} ↔ {matches[0].relative_path}  FAIL（哈希不一致！系统导出≠我们的导出，必须查）")
        pe_common.log(f"对照结果：一致 {verified} · 不一致 {mismatched} · 无同名清单行 {unmatched}")
        if mismatched:
            pe_common.log("存在不一致！把上面的 [对照] FAIL 行整段反馈回来排查。")

    # 4) 报告与总结
    report_path = pe_common.default_report_path(dest)
    pe_common.write_report(report, report_path)
    pe_common.log(f"报告：{report_path}")
    pe_common.log(f"结果：PASS {summary.passed} · 已验证跳过 {summary.skipped_verified} · "
                  f"FAIL {summary.failed} · 总量 {pe_common.bytes_str(summary.total_bytes)}")
    if orphans:
        if args.compare_orphans:
            pe_common.log(f"清单外文件 {len(orphans)} 个已拉到 {dest / '_原图对照'}（对照结果见上）。")
        else:
            pe_common.log(f"清单外文件 {len(orphans)} 个未拉取。")

    # 5) 护甲 ZIP
    if args.zip:
        if summary.failed:
            pe_common.log("有 FAIL 项，跳过打包（先解决失败再 --zip）。")
        else:
            zip_path = dest.parent / f"照片导出-{pe_common.stamp()}.zip"
            count, zipped = pe_common.make_store_zip(dest, zip_path)
            pe_common.log(f"仅存储 ZIP：{zip_path}（{count} 个文件，{pe_common.bytes_str(zipped)}，字节未动）")

    await lockdown.close()
    return 0 if summary.ok else 1


def main() -> int:
    pe_common.ensure_utf8_stdout()
    args = parse_args()
    if args.list:
        return asyncio.run(list_devices())
    if not args.dest:
        pe_common.log("需要 --dest 目标目录（或用 --list 先看设备）。")
        return 2
    if args.wifi is not None:  # 空串也算 WiFi 模式（拉取.bat 回车=自动发现）
        return wifi_pull(args)
    if args.coredevice:  # 强制 CoreDevice 通道（跳过 house_arrest）
        try:
            return asyncio.run(coredevice_amain(args))
        except KeyboardInterrupt:
            pe_common.log("\n已中断。重跑同一命令会续跑（已验证的文件自动跳过）。")
            return 130
        except Exception as error:
            pe_common.log(f"CoreDevice 通道失败：{error}")
            return 2
    try:
        return asyncio.run(amain(args))
    except KeyboardInterrupt:
        pe_common.log("\n已中断。重跑同一命令会续跑（已验证的文件自动跳过）。")
        return 130
    except Exception as error:
        pe_common.log(f"失败：{error}")
        pe_common.log("排查：①数据线已连且信任了电脑 ②装了 iTunes/Apple 设备驱动 ③手机上已跑过导出 ④试 --list 看设备")
        return 2


if __name__ == "__main__":
    sys.exit(main())
