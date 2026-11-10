# -*- coding: utf-8 -*-
"""verify.py：校验一个已经拉到电脑上的导出文件夹（爱思助手/iMazing/iTunes 拉的也算）。
逐文件重算 SHA-256 与 manifest.csv 比对，写 export-report-*.csv，全部一致退出码 0。

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
    parser = argparse.ArgumentParser(description="校验已拉取的导出文件夹（对照 manifest.csv）")
    parser.add_argument("folder", help="导出文件夹（内含 manifest.csv 与日期目录）")
    parser.add_argument("--manifest", help="manifest.csv 路径（默认 folder/manifest.csv）")
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
    report, summary = pe_common.verify_folder(folder, manifest_path=Path(args.manifest) if args.manifest else None)
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
