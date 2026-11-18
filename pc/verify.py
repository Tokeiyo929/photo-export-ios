# -*- coding: utf-8 -*-
"""verify.py：校验一个已经拉到电脑上的导出文件夹（爱思助手/iMazing/iTunes 拉的也算）。
自动探测两种清单：
  manifest.csv（旧版 App）→ 逐文件重算 SHA-256 与手机端哈希对账；
  index.txt（v4 传送带 App）→ 逐文件查大小，SHA-256 电脑现算留档（手机端无哈希基线）。
写 export-report.csv（固定名，每次覆盖），全 PASS 退出码 0。

用法：
  python pc/verify.py D:\\相册导出
  python pc/verify.py D:\\相册导出 --zip
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import pe_common  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="校验已拉取的导出文件夹（manifest.csv/index.txt 自动探测）")
    parser.add_argument("folder", help="导出文件夹（内含 manifest.csv 或 index.txt 与日期目录）")
    parser.add_argument("--manifest", help="manifest.csv 路径（默认 folder/manifest.csv，强制 manifest 模式）")
    parser.add_argument("--zip", action="store_true", help="校验通过后打仅存储 ZIP")
    return parser.parse_args()


def main() -> int:
    pe_common.ensure_utf8_stdout()
    args = parse_args()
    folder = Path(args.folder)
    if not folder.is_dir():
        pe_common.log(f"目录不存在：{folder}")
        return 2
    pe_common.log(f"校验 {folder} …")
    if args.manifest or (folder / pe_common.MANIFEST_NAME).exists():
        report, summary = pe_common.verify_folder(folder, manifest_path=Path(args.manifest) if args.manifest else None)
        mode = "manifest（对照手机端哈希）"
    elif (folder / pe_common.INDEX_NAME).exists():
        report, summary = pe_common.verify_folder_index(folder)
        mode = "index（v4 传送带，电脑端现算哈希留档）"
    else:
        pe_common.log("目录里既没有 manifest.csv 也没有 index.txt。")
        pe_common.log("旧版 App：拖出的目录应含 manifest.csv；v4 App：请拖 Library/Application Support/PhotoExport/（photos/ 与 index.txt 在里面）。")
        return 2
    pe_common.log(f"清单模式：{mode}")
    report_path = pe_common.default_report_path(folder)
    pe_common.write_report(report, report_path)
    pe_common.log(f"报告：{report_path}")
    pe_common.log(f"结果：PASS {summary.passed} · MISSING {summary.missing} · FAIL {summary.failed} · "
                  f"EXTRA {summary.extra} · 总量 {pe_common.bytes_str(summary.total_bytes)}")
    if args.zip:
        if summary.ok:
            zip_path = folder.parent / f"照片导出-{pe_common.stamp()}.zip"
            count, zipped = pe_common.make_store_zip(folder, zip_path)
            pe_common.log(f"仅存储 ZIP：{zip_path}（{count} 个文件，{pe_common.bytes_str(zipped)}，字节未动）")
        else:
            pe_common.log("有 FAIL/MISSING 项，跳过打包。")
    return 0 if summary.ok else 1


if __name__ == "__main__":
    sys.exit(main())
