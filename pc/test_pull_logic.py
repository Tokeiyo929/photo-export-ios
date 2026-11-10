# -*- coding: utf-8 -*-
"""pe_common 的单元测试：清单解析、目录校验、仅存储 ZIP、报告。
运行：python -m unittest discover -s pc -p 'test_*.py'"""
from __future__ import annotations

import csv
import hashlib
import io
import unittest
import zipfile
from pathlib import Path

import pe_common

HEADER = ",".join(pe_common.MANIFEST_HEADER)


def manifest_row(rel: str, data: bytes, status: str = "OK") -> str:
    sha = hashlib.sha256(data).hexdigest()
    favorite = "0"
    return f"{rel},{len(data)},{sha},creation,ASSET-1,photo,{favorite},{status},2026-11-10T00:00:00Z,"


class ManifestParsingTest(unittest.TestCase):
    def test_roundtrip_with_bom_and_quoting(self):
        data = b"\xef\xbb\xbf" + HEADER.encode("utf-8") + "\n".encode("utf-8")
        tricky = "2026/2026-03-15/照片, 一\"奇\".HEIC"
        # 用 csv.writer 生成规范转义行（与 App 端 Swift 写法一致：引号翻倍、含逗号加引号）
        buffer = io.StringIO()
        csv.writer(buffer, lineterminator="").writerow(
            [tricky, "5", "a" * 64, "creation", "id", "photo", "0", "OK",
             "2026-01-01T00:00:00Z", '备注"x"'])
        raw = data + buffer.getvalue().encode("utf-8") + b"\n"
        rows, malformed = pe_common.parse_manifest_bytes(raw)
        self.assertEqual(malformed, 0)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].relative_path, tricky)
        self.assertEqual(rows[0].note, '备注"x"')
        self.assertEqual(rows[0].status, "OK")

    def test_malformed_and_header_skipped(self):
        raw = (HEADER + "\nshort-line-only\n"
               + "a/b.HEIC,1," + "0" * 64 + ",creation,id,photo,0,OK,t,\n").encode("utf-8")
        rows, malformed = pe_common.parse_manifest_bytes(raw)
        self.assertEqual((len(rows), malformed), (1, 1))

    def test_last_wins(self):
        old = pe_common.ManifestRow(relative_path="a.HEIC", status="FAIL")
        new = pe_common.ManifestRow(relative_path="a.HEIC", status="OK")
        rows = pe_common.last_wins([old, new])
        self.assertEqual(rows[0].status, "OK")


class VerifyFolderTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.folder = Path(tempfile.mkdtemp(prefix="pe-test-"))
        self.payload_a = b"AAA" * 100
        self.payload_b = b"BBB" * 200
        (self.folder / "2026/2026-03-15").mkdir(parents=True)
        (self.folder / "2026/2026-03-15/a.HEIC").write_bytes(self.payload_a)
        (self.folder / "2026/2026-03-15/b.MOV").write_bytes(self.payload_b)
        lines = [HEADER,
                 manifest_row("2026/2026-03-15/a.HEIC", self.payload_a),
                 manifest_row("2026/2026-03-15/b.MOV", self.payload_b)]
        (self.folder / pe_common.MANIFEST_NAME).write_text("\n".join(lines) + "\n",
                                                           encoding="utf-8")

    def test_all_pass(self):
        report, summary = pe_common.verify_folder(self.folder)
        self.assertTrue(summary.ok)
        self.assertEqual(summary.passed, 2)
        self.assertEqual(summary.extra, 0)
        results = {r["relative_path"]: r["result"] for r in report}
        self.assertEqual(results["2026/2026-03-15/a.HEIC"], "PASS")

    def test_tampered_file_fails(self):
        target = self.folder / "2026/2026-03-15/a.HEIC"
        target.write_bytes(b"XXX" * 100)
        report, summary = pe_common.verify_folder(self.folder)
        self.assertFalse(summary.ok)
        self.assertEqual(summary.failed, 1)
        bad = [r for r in report if r["result"] == "FAIL"]
        self.assertEqual(len(bad), 1)
        self.assertEqual(bad[0]["relative_path"], "2026/2026-03-15/a.HEIC")

    def test_missing_file_reported(self):
        (self.folder / "2026/2026-03-15/b.MOV").unlink()
        _, summary = pe_common.verify_folder(self.folder)
        self.assertFalse(summary.ok)
        self.assertEqual(summary.missing, 1)

    def test_extra_file_warned(self):
        (self.folder / "2026/2026-03-15/c.RAW").write_bytes(b"extra")
        _, summary = pe_common.verify_folder(self.folder)
        self.assertTrue(summary.ok)  # EXTRA 不算失败，但要可见
        self.assertEqual(summary.extra, 1)

    def test_fast_resume_skips_hash(self):
        report, summary = pe_common.verify_folder(self.folder, hash_existing=False)
        self.assertTrue(summary.ok)
        self.assertEqual(summary.skipped_verified, 2)
        self.assertTrue(all(r["result"] == "SKIP-VERIFIED" for r in report))

    def test_report_csv_roundtrip(self):
        report, _ = pe_common.verify_folder(self.folder)
        report_path = self.folder / "report.csv"
        pe_common.write_report(report, report_path)
        with open(report_path, newline="", encoding="utf-8-sig") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["result"], "PASS")


class StoreZipTest(unittest.TestCase):
    def test_stored_and_byte_equal(self):
        import tempfile
        folder = Path(tempfile.mkdtemp(prefix="pe-zip-"))
        payload = bytes(range(256)) * 100
        (folder / "2026").mkdir(parents=True)
        (folder / "2026/x.HEIC").write_bytes(payload)
        zip_path = folder.parent / "out.zip"
        count, total = pe_common.make_store_zip(folder, zip_path)
        self.assertEqual((count, total), (1, len(payload)))
        with zipfile.ZipFile(zip_path) as archive:
            infos = archive.infolist()
            self.assertEqual(len(infos), 1)
            self.assertEqual(infos[0].compress_type, zipfile.ZIP_STORED)
            self.assertEqual(archive.read(infos[0]), payload)  # 字节原封不动


if __name__ == "__main__":
    unittest.main()
