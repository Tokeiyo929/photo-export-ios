# -*- coding: utf-8 -*-
"""pe_common 的单元测试：清单解析、目录校验、仅存储 ZIP、报告。
运行：python -m unittest discover -s pc -p 'test_*.py'"""
from __future__ import annotations

import argparse
import csv
import hashlib
import http.server
import io
import threading
import unittest
import urllib.parse
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

    def test_pulled_status_parsed(self):
        raw = (HEADER + "\n"
               + "a/b.HEIC,5," + "0" * 64
               + ",creation,id,photo,0,PULLED,2026-11-10T00:00:00Z,已拉取到电脑，手机端已清理\n").encode("utf-8")
        rows, malformed = pe_common.parse_manifest_bytes(raw)
        self.assertEqual((len(rows), malformed), (1, 0))
        self.assertEqual(rows[0].status, "PULLED")
        self.assertEqual(rows[0].note, "已拉取到电脑，手机端已清理")

    def test_pullable_rows_skips_pulled_and_fail(self):
        rows = [
            pe_common.ManifestRow(relative_path="ok.HEIC", status="OK"),
            pe_common.ManifestRow(relative_path="pulled.HEIC", status="PULLED"),
            pe_common.ManifestRow(relative_path="fail.HEIC", status="FAIL"),
        ]
        self.assertEqual([r.relative_path for r in pe_common.pullable_rows(rows)], ["ok.HEIC"])

    def test_last_wins_ok_to_pulled_not_pullable(self):
        rows = [
            pe_common.ManifestRow(relative_path="a.HEIC", status="OK"),
            pe_common.ManifestRow(relative_path="a.HEIC", status="PULLED"),
        ]
        self.assertEqual(pe_common.pullable_rows(rows), [])


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

    def test_pulled_row_still_verified_when_file_present(self):
        # 清理前的场景：手机端改记 PULLED，但电脑上这批文件还在 —— 校验照样要覆盖它
        payload_c = b"CCC" * 50
        (self.folder / "2026/2026-03-15/c.HEIC").write_bytes(payload_c)
        with open(self.folder / pe_common.MANIFEST_NAME, "a", encoding="utf-8") as handle:
            handle.write(manifest_row("2026/2026-03-15/c.HEIC", payload_c, status="PULLED") + "\n")
        report, summary = pe_common.verify_folder(self.folder)
        self.assertTrue(summary.ok)
        self.assertEqual(summary.passed, 3)

    def test_pulled_row_missing_not_error_when_absent(self):
        # 清理后的场景（手机端文件已删）：新 --dest 里自然没有 PULLED 文件。
        # verify_folder 以清单为准逐文件查，PULLED 且文件不在 → MISSING（提示同一 --dest 续用）
        with open(self.folder / pe_common.MANIFEST_NAME, "a", encoding="utf-8") as handle:
            handle.write(manifest_row("2026/2026-03-15/gone.HEIC", b"ZZZ", status="PULLED") + "\n")
        report, summary = pe_common.verify_folder(self.folder)
        self.assertFalse(summary.ok)
        self.assertEqual(summary.missing, 1)


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


class _WifiFixtureHandler(http.server.BaseHTTPRequestHandler):
    """最小 WiFi 服务回路：/manifest.csv、/file/<rel>，从 fixture 目录读。"""
    root: Path = Path(".")

    def do_GET(self):
        if self.path == "/manifest.csv":
            self._send((self.root / "manifest.csv").read_bytes())
        elif self.path.startswith("/file/"):
            rel = urllib.parse.unquote(self.path[len("/file/"):])
            try:
                self._send((self.root / rel).read_bytes())
            except OSError:
                self.send_error(404)
        else:
            self.send_error(404)

    def _send(self, data: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass  # 静音测试输出


class WifiPullTest(unittest.TestCase):
    def _row(self, rel: str, data: bytes) -> str:
        # 与 App 端写法一致：含逗号的文件名要 csv 转义（引号包裹）
        sha = hashlib.sha256(data).hexdigest()
        fields = [rel, str(len(data)), sha, "creation", "ASSET-1", "photo", "0", "OK",
                  "2026-11-10T00:00:00Z", ""]
        buffer = io.StringIO()
        csv.writer(buffer, lineterminator="").writerow(fields)
        return buffer.getvalue()

    def _run_wifi(self, root: Path, dest: Path) -> int:
        import contextlib
        import pull
        handler = type("H", (_WifiFixtureHandler,), {"root": root})
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_address[1]}"
            args = argparse.Namespace(wifi=url, dest=str(dest), fast_resume=False, zip=False)
            with contextlib.redirect_stdout(io.StringIO()):
                return pull.wifi_pull(args)
        finally:
            server.shutdown()
            server.server_close()

    def test_wifi_pull_pass_and_verify(self):
        import tempfile
        root = Path(tempfile.mkdtemp(prefix="pe-wifi-root"))
        dest = Path(tempfile.mkdtemp(prefix="pe-wifi-dest"))
        rows = []
        payloads = {
            "2024/2024-11-24/IMG_1.HEIC": b"heic-bytes-\x00\xff" * 10,
            "2026/2026-03-15/照片, 一.MOV": b"mov-bytes-\x01\x02" * 5,  # 中文名+逗号+空格
        }
        for rel, data in payloads.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_bytes(data)
            rows.append(self._row(rel, data))
        (root / "manifest.csv").write_bytes(b"\xef\xbb\xbf" + HEADER.encode("utf-8") + b"\n"
                                            + "".join(r + "\n" for r in rows).encode("utf-8"))
        rc = self._run_wifi(root, dest)
        self.assertEqual(rc, 0)
        for rel, data in payloads.items():
            self.assertEqual((dest / rel).read_bytes(), data)
        reports = sorted(dest.glob("export-report-*.csv"))
        self.assertTrue(reports, "报告未生成")
        with open(reports[-1], encoding="utf-8-sig") as handle:
            statuses = [r["result"] for r in csv.DictReader(handle)]
        self.assertEqual(statuses.count("PASS"), 2)

    def test_wifi_pull_hash_mismatch_fails(self):
        import tempfile
        root = Path(tempfile.mkdtemp(prefix="pe-wifi-root2"))
        dest = Path(tempfile.mkdtemp(prefix="pe-wifi-dest2"))
        rel = "2024/a.HEIC"
        (root / rel).parent.mkdir(parents=True)
        (root / rel).write_bytes(b"actual-bytes")
        # 清单声明的是另一份数据的哈希 → 服务端文件被篡改 → 必须 FAIL
        rows = [self._row(rel, b"declared-bytes")]
        (root / "manifest.csv").write_bytes(b"\xef\xbb\xbf" + HEADER.encode("utf-8") + b"\n"
                                            + "".join(r + "\n" for r in rows).encode("utf-8"))
        rc = self._run_wifi(root, dest)
        self.assertEqual(rc, 1)
        reports = sorted(dest.glob("export-report-*.csv"))
        self.assertTrue(reports, "报告未生成")
        with open(reports[-1], encoding="utf-8-sig") as handle:
            statuses = [r["result"] for r in csv.DictReader(handle)]
        self.assertEqual(statuses, ["FAIL"])


if __name__ == "__main__":
    unittest.main()
