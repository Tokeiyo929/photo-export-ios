# -*- coding: utf-8 -*-
"""pe_common：manifest 解析、SHA-256、目录校验、仅存储 ZIP。
纯标准库，App 端（Swift）与 PC 端共用的清单语义在这里落地。"""
from __future__ import annotations

import csv
import hashlib
import io
import os
import sys
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional, Tuple

MANIFEST_NAME = "manifest.csv"
MANIFEST_HEADER = ["relative_path", "size", "sha256", "date_source", "asset_id",
                   "media_type", "favorite", "status", "exported_at", "note"]
CHUNK = 1024 * 1024


@dataclass
class ManifestRow:
    relative_path: str = ""
    size: int = 0
    sha256: str = ""
    date_source: str = ""
    asset_id: str = ""
    media_type: str = ""
    favorite: str = ""
    status: str = ""          # OK（在手机待拉取）/ PULLED（已拉取清理，电脑为唯一副本）/ FAIL
    exported_at: str = ""
    note: str = ""


@dataclass
class VerifySummary:
    passed: int = 0
    skipped_verified: int = 0
    failed: int = 0
    missing: int = 0
    extra: int = 0
    total_bytes: int = 0

    @property
    def ok(self) -> bool:
        return self.failed == 0 and self.missing == 0


def log(msg: str) -> None:
    print(msg, flush=True)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while True:
            block = handle.read(CHUNK)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def parse_manifest_bytes(raw: bytes) -> Tuple[List[ManifestRow], int]:
    """解析 manifest.csv 字节（容忍 BOM）。返回 (行, 损坏行数)。"""
    text = raw.decode("utf-8-sig", errors="replace")
    reader = csv.reader(io.StringIO(text, newline=""))
    rows: List[ManifestRow] = []
    malformed = 0
    for fields in reader:
        if not fields or all(not f.strip() for f in fields):
            continue
        if fields[0] == "relative_path":
            continue  # 表头
        if len(fields) < len(MANIFEST_HEADER):
            malformed += 1
            continue
        row = ManifestRow(*fields[: len(MANIFEST_HEADER)])
        row.size = to_int(fields[1])
        if row.status not in ("OK", "PULLED", "FAIL") or not row.relative_path:
            malformed += 1
            continue
        rows.append(row)
    return rows, malformed


def to_int(text: str) -> int:
    try:
        return int(text)
    except (TypeError, ValueError):
        return 0


def last_wins(rows: Iterable[ManifestRow]) -> List[ManifestRow]:
    """同一 relative_path 多行时取最后一行（App 端是追加式日志）。"""
    result: dict[str, ManifestRow] = {}
    for row in rows:
        result[row.relative_path] = row
    return list(result.values())


def pullable_rows(rows: Iterable[ManifestRow]) -> List[ManifestRow]:
    """待拉取的行：last_wins 后仍为 OK 的。
    PULLED=已拉取清理（手机端文件已删，不能再拉）；FAIL=失败待重试（设备上也没有文件）。"""
    return [r for r in last_wins(rows) if r.status == "OK"]


def local_path(folder: Path, relative_path: str) -> Path:
    """清单里用 '/' 分隔；Windows 上 join 回本地分隔符。"""
    parts = [p for p in relative_path.split("/") if p not in ("", ".")]
    return folder.joinpath(*parts)


def verify_folder(folder: Path, manifest_path: Optional[Path] = None,
                  hash_existing: bool = True,
                  progress=None) -> Tuple[List[dict], VerifySummary]:
    """对已拉取的文件夹逐文件校验。
    返回 (报告行, 总结)。result: PASS / SKIP-VERIFIED / FAIL / MISSING / EXTRA。
    hash_existing=False 时（pull.py 的续跑快速路径），同大小文件只比对大小不重算哈希。"""
    manifest_path = manifest_path or folder / MANIFEST_NAME
    summary = VerifySummary()
    report: List[dict] = []
    if not manifest_path.exists():
        summary.failed = 1
        report.append({"relative_path": MANIFEST_NAME, "expected_sha256": "", "actual_sha256": "",
                       "size": 0, "result": "MISSING", "note": "清单不存在：" + str(manifest_path)})
        return report, summary
    rows, malformed = parse_manifest_bytes(manifest_path.read_bytes())
    # OK 与 PULLED 都要校验：PULLED 的哈希仍在清单里，文件夹里存有该文件（清理前拉出的）就照样验
    expected = {r.relative_path: r for r in last_wins(rows) if r.status in ("OK", "PULLED")}

    seen = set()
    for relative_path, row in expected.items():
        target = local_path(folder, relative_path)
        if not target.exists():
            summary.missing += 1
            report.append(_report_row(relative_path, row.sha256, "", row.size, "MISSING", "文件不存在"))
            if progress:
                progress(relative_path, "MISSING")
            continue
        actual_size = target.stat().st_size
        if actual_size != row.size:
            summary.failed += 1
            report.append(_report_row(relative_path, row.sha256, "", actual_size, "FAIL",
                                      f"大小不符 清单={row.size} 实际={actual_size}"))
            if progress:
                progress(relative_path, "FAIL")
            continue
        if not hash_existing:
            summary.skipped_verified += 1
            summary.total_bytes += actual_size
            report.append(_report_row(relative_path, row.sha256, "(fast-resume)", actual_size,
                                      "SKIP-VERIFIED", "同大小，未重算哈希（--fast-resume）"))
            if progress:
                progress(relative_path, "SKIP-VERIFIED")
            continue
        actual_sha = sha256_file(target)
        if actual_sha == row.sha256:
            summary.passed += 1
            summary.total_bytes += actual_size
            report.append(_report_row(relative_path, row.sha256, actual_sha, actual_size, "PASS", ""))
        else:
            summary.failed += 1
            report.append(_report_row(relative_path, row.sha256, actual_sha, actual_size, "FAIL", "哈希不一致"))
            if progress:
                progress(relative_path, "FAIL")
        seen.add(relative_path)

    # 磁盘上多出来的文件（清单里没有的）
    for path in sorted(folder.rglob("*")):
        if not path.is_file() or path == manifest_path:
            continue
        relative = path.relative_to(folder).as_posix()
        if relative not in expected:
            summary.extra += 1
            report.append(_report_row(relative, "", "", path.stat().st_size, "EXTRA",
                                      "磁盘存在但清单未记录"))
    if malformed:
        log(f"警告：清单损坏行 {malformed} 条（已跳过）")
    return report, summary


def _report_row(relative_path: str, expected_sha: str, actual_sha: str,
                size: int, result: str, note: str) -> dict:
    return {"relative_path": relative_path, "expected_sha256": expected_sha,
            "actual_sha256": actual_sha, "size": size, "result": result, "note": note}


REPORT_HEADER = ["relative_path", "expected_sha256", "actual_sha256", "size", "result", "note"]


def write_report(report: Iterable[dict], path: Path) -> None:
    with open(path, "w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=REPORT_HEADER)
        writer.writeheader()
        writer.writerows(report)


def make_store_zip(folder: Path, zip_path: Path) -> Tuple[int, int]:
    """仅存储（ZIP_STORED）模式打包：字节原封不动，只加目录与 CRC32。
    微信/QQ 按文件发 ZIP 即绕开图片二次压缩。返回 (文件数, 总字节)。"""
    count = 0
    total = 0
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_STORED) as archive:
        for path in sorted(folder.rglob("*")):
            if not path.is_file() or path == zip_path:
                continue
            archive.write(path, arcname=path.relative_to(folder).as_posix(),
                          compress_type=zipfile.ZIP_STORED)
            count += 1
            total += path.stat().st_size
    return count, total


def bytes_str(value: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(value) < 1024:
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{value:.1f} PB"


def stamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def ensure_utf8_stdout() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        try:
            sys.stdout.reconfigure(encoding="utf-8")
            sys.stderr.reconfigure(encoding="utf-8")
        except Exception:
            pass


def default_report_path(folder: Path) -> Path:
    return folder / f"export-report-{stamp()}.csv"
