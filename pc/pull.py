# -*- coding: utf-8 -*-
"""pull.py：数据线（usbmuxd/AFC/house_arrest）从 App 沙盒 Documents 拉取原片到电脑，
并逐文件用 SHA-256 与 manifest.csv 比对，出 export-report.csv；--zip 顺带打仅存储包。

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
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pe_common  # noqa: E402

DEFAULT_BUNDLE = "com.tokeiyo929.photoexport"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="数据线拉取 App 导出的原片并校验哈希")
    parser.add_argument("--list", action="store_true", help="列出已连接设备")
    parser.add_argument("--udid", help="设备 serial（多台时用 --list 查看）")
    parser.add_argument("--app", default=DEFAULT_BUNDLE, help=f"App bundle id（默认 {DEFAULT_BUNDLE}）")
    parser.add_argument("--dest", help="拉取目标目录")
    parser.add_argument("--zip", action="store_true", help="校验通过后打仅存储 ZIP")
    parser.add_argument("--fast-resume", action="store_true",
                        help="续跑时同大小文件不重算哈希（快，但少一道证明）")
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

    # 解析实际 bundle id：Sideloadly 免签重签会在原 id 后追加团队后缀
    # （如 com.tokeiyo929.photoexport.FBTKZ8C6QB），先精确匹配再前缀匹配。
    bundle = args.app
    try:
        installed = await InstallationProxyService(lockdown).get_apps()
        if bundle not in installed:
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
    except Exception as error:
        pe_common.log(f"枚举已装 App 失败（继续按原名尝试）：{error}")

    pe_common.log(f"打开 App 沙盒（house_arrest/VendDocuments）：{bundle}")
    # create 工厂 = 构造 + await send_command(VendDocuments)，出错自动关闭
    house = await HouseArrestService.create(lockdown, bundle, documents_only=True)

    # 1) 读清单
    try:
        manifest_bytes = await house.get_file_contents(pe_common.MANIFEST_NAME)
    except Exception as error:
        pe_common.log(f"读取 manifest.csv 失败：{error}")
        pe_common.log("请确认 App 已在手机上跑过一次导出，bundle id 是否正确（--app）。")
        return 2
    rows, malformed = pe_common.parse_manifest_bytes(manifest_bytes)
    expected = pe_common.pullable_rows(rows)
    pulled_note = ""
    if any(r.status == "PULLED" for r in pe_common.last_wins(rows)):
        pulled_note = "（PULLED 的已拉取清理，跳过）"
    pe_common.log(f"清单：待拉取 {len(expected)} 个文件{pulled_note}"
                  + (f"，损坏行 {malformed}" if malformed else ""))

    # 2) 枚举设备端文件（顺带发现清单之外的孤儿文件）
    device_files: dict[str, int] = {}

    async def walk_dir(prefix: str) -> None:
        for name in await house.listdir(prefix or "/"):
            if name.startswith("."):
                continue
            path = f"{prefix}/{name}".replace("//", "/")
            if await house.isdir(path):
                await walk_dir(path)
            else:
                stat = await house.stat(path)
                device_files[path.lstrip("/")] = stat.get("st_size", 0)

    await walk_dir("")
    known = {r.relative_path for r in expected}
    orphans = [p for p in device_files if p != pe_common.MANIFEST_NAME and p not in known]
    if orphans:
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
        # 拉取（App 端按日期归档的相对路径）
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            await house.pull(rel, str(target.parent))
        except Exception as error:
            summary.failed += 1
            report.append(pe_common._report_row(rel, row.sha256, "", 0, "ERROR", f"拉取失败：{error}"))
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
            report.append(pe_common._report_row(rel, row.sha256, actual_sha, actual_size, "PASS", ""))
            pe_common.log(f"{prefix} PASS  {rel}  ({pe_common.bytes_str(actual_size)})")

    # 4) 报告与总结
    report_path = pe_common.default_report_path(dest)
    pe_common.write_report(report, report_path)
    pe_common.log(f"报告：{report_path}")
    pe_common.log(f"结果：PASS {summary.passed} · 已验证跳过 {summary.skipped_verified} · "
                  f"FAIL {summary.failed} · 总量 {pe_common.bytes_str(summary.total_bytes)}")
    if orphans:
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
