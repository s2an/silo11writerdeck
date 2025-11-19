# tests/test_export_http_server.py
import os
import time
import http.client
import contextlib
import pytest

# import the run_server and lan_ips from the drop-in module
from http_server.export_http_server import run_server as _run_server
from http_server.export_http_server import lan_ips


def _http_get(host, port, path="/"):
    conn = http.client.HTTPConnection(host, port, timeout=3)
    conn.request("GET", path)
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    return resp, body


def test_single_file_download_headers_and_body(tmp_path):
    export_dir = tmp_path
    target = export_dir / "parcel.txt"
    content = b"hello-world\n"
    target.write_bytes(content)

    with _run_server(
        export_dir=str(export_dir),
        serve_file=str(target),
        allow_list=False,
    ) as (host, port):
        resp, body = _http_get(host, port, "/anything/ignored")
        assert resp.status == 200
        assert body == content
        cd = resp.getheader("Content-Disposition", "")
        assert "attachment;" in cd
        assert 'filename="parcel.txt"' in cd
        assert resp.getheader("Cache-Control") == "no-store"
        # Content-Type guessed by SimpleHTTPRequestHandler
        assert resp.getheader("Content-Type") in ("text/plain", "text/plain; charset=utf-8")


def test_directory_listing_disabled_returns_403(tmp_path):
    export_dir = tmp_path
    (export_dir / "sub").mkdir()

    with _run_server(
        export_dir=str(export_dir),
        serve_file=None,
        allow_list=False,
    ) as (host, port):
        resp, _ = _http_get(host, port, "/sub/")
        assert resp.status == 403


def test_directory_listing_enabled_allows_index(tmp_path):
    export_dir = tmp_path
    # No index.html: SimpleHTTPRequestHandler will render a listing
    sample = export_dir / "readme.txt"
    sample.write_text("note")

    with _run_server(
        export_dir=str(export_dir),
        serve_file=None,
        allow_list=True,
    ) as (host, port):
        resp, body = _http_get(host, port, "/")
        assert resp.status == 200
        assert b"readme.txt" in body
        assert resp.getheader("Content-Type", "").startswith("text/html")


def test_path_traversal_is_blocked(tmp_path):
    export_dir = tmp_path
    with _run_server(
        export_dir=str(export_dir),
        serve_file=None,
        allow_list=False,
    ) as (host, port):
        # Try to climb out of base_dir
        resp, _ = _http_get(host, port, "/../../etc/passwd")
        # Handler sends 403 for forbidden; allow 404 on odd platforms
        assert resp.status in (403, 404)


def test_missing_file_returns_404(tmp_path):
    export_dir = tmp_path
    with _run_server(
        export_dir=str(export_dir),
        serve_file=None,
        allow_list=False,
    ) as (host, port):
        resp, _ = _http_get(host, port, "/nope.txt")
        assert resp.status == 404


def test_favicon_is_quiet_404(tmp_path):
    export_dir = tmp_path
    with _run_server(
        export_dir=str(export_dir),
        serve_file=None,
        allow_list=False,
    ) as (host, port):
        resp, _ = _http_get(host, port, "/favicon.ico")
        assert resp.status == 404


def test_lan_ips_dedup_and_order(monkeypatch):
    # make lan_ips deterministic for test
    monkeypatch.setattr.__module__  # silence IDEs (no-op)

    # Patch hostname
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setenv = None
    import socket

    monkeypatch.setattr(socket, "gethostname", lambda: "raspberrypi")

    class _FakeSock:
        def connect(self, *args, **kwargs):
            return None
        def getsockname(self):
            return ("192.168.0.123", 54321)
        def close(self):
            return None

    monkeypatch.setattr(socket, "socket", lambda *a, **k: _FakeSock())

    class _FakePopenOut:
        def read(self):
            return "192.168.0.123 10.0.0.5"

    monkeypatch.setattr(os, "popen", lambda cmd: _FakePopenOut())

    ips = lan_ips()
    assert ips[0] == ("mDNS", "raspberrypi.local")
    assert ("LAN", "192.168.0.123") in ips
    assert ("LAN", "10.0.0.5") in ips
    assert len({v for _, v in ips}) == len(ips)
