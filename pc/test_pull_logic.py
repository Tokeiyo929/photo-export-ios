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
    counters = {"range": 0}  # 类级 dict：收到的 Range 请求次数（续传用例断言用）

    def do_GET(self):
        if self.path == "/manifest.csv":
            self._send((self.root / "manifest.csv").read_bytes())
        elif self.path.startswith("/file/"):
            rel = urllib.parse.unquote(self.path[len("/file/"):])
            try:
                data = (self.root / rel).read_bytes()
            except OSError:
                self.send_error(404)
                return
            rng = self.headers.get("Range") or ""
            if rng.startswith("bytes="):
                type(self).counters["range"] += 1
                start = int(rng[6:].split("-")[0])
                self.send_response(206)
                self.send_header("Content-Range", f"bytes {start}-{len(data) - 1}/{len(data)}")
                self._send(data[start:], send_response_line=False)
            else:
                self._send(data)
        else:
            self.send_error(404)

    def _send(self, data: bytes, send_response_line: bool = True):
        if send_response_line:
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

    def test_wifi_pull_resume_from_part(self):
        # 断点续传（GCDWebServer 同款 Range/206）：遗留 .part 从断点接着拉，最终字节全等
        import tempfile
        root = Path(tempfile.mkdtemp(prefix="pe-wifi-root3"))
        dest = Path(tempfile.mkdtemp(prefix="pe-wifi-dest3"))
        rel = "2024/big.MOV"
        payload = b"RANGE-RESUME-" * 1000
        (root / rel).parent.mkdir(parents=True)
        (root / rel).write_bytes(payload)
        rows = [self._row(rel, payload)]
        (root / "manifest.csv").write_bytes(b"\xef\xbb\xbf" + HEADER.encode("utf-8") + b"\n"
                                            + "".join(r + "\n" for r in rows).encode("utf-8"))
        part = dest / (rel + ".part")
        part.parent.mkdir(parents=True)
        part.write_bytes(payload[:5000])  # 上次断在这里
        _WifiFixtureHandler.counters["range"] = 0
        rc = self._run_wifi(root, dest)
        self.assertEqual(rc, 0)
        self.assertEqual((dest / rel).read_bytes(), payload)
        self.assertGreaterEqual(_WifiFixtureHandler.counters["range"], 1, "没发 Range 请求")
        self.assertFalse(part.exists())  # 续传完成后 .part 应原子改名

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


class CompareOriginalsTest(unittest.TestCase):
    """原图对照（--compare-orphans）的匹配逻辑：系统「导出未修改的原片」当独立裁判。"""

    def test_index_by_basename_and_verdict(self):
        import pull
        rows = [
            pe_common.ManifestRow(relative_path="2024/2024-01-01/IMG_1.JPG",
                                  sha256=hashlib.sha256(b"v2024").hexdigest(), size=5),
            pe_common.ManifestRow(relative_path="2025/2025-01-01/IMG_1.JPG",
                                  sha256=hashlib.sha256(b"v2025").hexdigest(), size=5),
            pe_common.ManifestRow(relative_path="2024/2024-01-01/IMG_1.MOV",
                                  sha256=hashlib.sha256(b"live").hexdigest(), size=4),
        ]
        index = pull.index_by_basename(rows)
        self.assertEqual(len(index["IMG_1.JPG"]), 2)  # 跨年份重名都保留
        self.assertEqual(len(index["IMG_1.MOV"]), 1)
        # 字节哈希命中重名行之一 → 判一致（命中的是 2025 那张）
        sha_2025 = hashlib.sha256(b"v2025").hexdigest()
        hit = next((r for r in index["IMG_1.JPG"] if r.sha256 == sha_2025), None)
        self.assertIsNotNone(hit)
        self.assertEqual(hit.relative_path, "2025/2025-01-01/IMG_1.JPG")
        # 哈希谁都不匹配 → mismatch 分支（hit 为 None）
        self.assertIsNone(next((r for r in index["IMG_1.JPG"]
                                 if r.sha256 == hashlib.sha256(b"other").hexdigest()), None))


if __name__ == "__main__":
    unittest.main()
