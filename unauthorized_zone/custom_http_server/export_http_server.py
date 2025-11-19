#!/usr/bin/env python3
"""
Drop-in HTTP export server for tests.

Provides:
- lan_ips() utility
- DownloadOnlyHandler (SimpleHTTPRequestHandler subclass)
- run_server(contextmanager) for tests to start a temporary server

This file is intended to be imported by tests as:
from http_server import export_http_server as srv
or
from http_server.export_http_server import run_server
"""
from __future__ import annotations

import os
import socket
import socketserver
import sys
import time
import threading
import contextlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

DEFAULT_PORT = 8080
DEFAULT_EXPORT_DIR = os.path.expanduser("~")


def lan_ips():
    """Discover a few useful LAN address hints (mDNS + LAN IPs)."""
    names = []
    try:
        names.append(("mDNS", f"{socket.gethostname()}.local"))
    except Exception:
        pass
    # cheap LAN IP discovery (no packet actually sent)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        names.append(("LAN", s.getsockname()[0]))
        s.close()
    except Exception:
        pass
    # hostname -I
    try:
        addrs = os.popen("hostname -I").read().strip().split()
        for a in addrs:
            names.append(("LAN", a))
    except Exception:
        pass
    # dedupe, preserve order
    seen, uniq = set(), []
    for k, v in names:
        if v and v not in seen:
            seen.add(v)
            uniq.append((k, v))
    return uniq or [("loopback", "127.0.0.1")]


class DownloadOnlyHandler(SimpleHTTPRequestHandler):
    """
    Read-only HTTP handler that:
      - In single-file mode (serve_single_file set), serves that file for ANY request.
      - Optionally allows directory listing when allow_dir_list is True.
      - Sets Content-Disposition: attachment and Cache-Control: no-store for file responses.
    """
    serve_single_file: str | None = None
    allow_dir_list: bool = False
    base_dir: str | None = None

    def translate_path(self, path: str) -> str:
        """Resolve request path to a filesystem path.

        If serve_single_file is set, always return that file's absolute path.
        Otherwise resolve relative to base_dir (if set) or cwd.
        """
        # Always serve the configured single file (if any)
        serve = getattr(self, "serve_single_file", None)
        if serve:
            return os.path.abspath(serve)

        # Normal resolution relative to base_dir
        path = unquote(path)
        if path.startswith("/"):
            path = path[1:]
        base = getattr(self, "base_dir", None) or os.getcwd()
        full_path = os.path.abspath(os.path.join(base, path))
        return full_path

    def list_directory(self, path):
        """Allow directory listing only when allowed."""
        if not bool(getattr(self, "allow_dir_list", False)):
            self.send_error(403, "Directory listing disabled")
            return None
        return super().list_directory(path)

    def send_head(self):
        """Send headers and return file object for GET/HEAD.

        If serve_single_file is set, this sends the file with attachment headers.
        Otherwise fall back to SimpleHTTPRequestHandler.send_head().
        """
        serve = getattr(self, "serve_single_file", None)
        if serve:
            # Resolve using translate_path to support absolute/relative config
            path = self.translate_path(self.path)
            if os.path.exists(path) and os.path.isfile(path):
                try:
                    f = open(path, "rb")
                except OSError:
                    self.send_error(404, "File not found")
                    return None
                self.send_response(200)
                ctype = self.guess_type(path) or "application/octet-stream"
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(os.path.getsize(path)))
                self.send_header(
                    "Content-Disposition",
                    f'attachment; filename="{os.path.basename(path)}"',
                )
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                return f
            else:
                self.send_error(404, "File not found")
                return None
        # Default behavior
        return super().send_head()

    def do_GET(self):
        # Quiet favicon requests
        if self.path == "/favicon.ico":
            self.send_error(404, "Not found")
            return
        super().do_GET()


@contextlib.contextmanager
def run_server(export_dir: str, serve_file: str | None = None, allow_list: bool = False):
    """
    Context manager for tests.

    Usage:
        with run_server(export_dir, serve_file=..., allow_list=True) as (host, port):
            ...
    """
    prev_cwd = os.getcwd()
    os.chdir(export_dir)

    class Handler(DownloadOnlyHandler):
        base_dir = export_dir
        serve_single_file = serve_file
        allow_dir_list = bool(allow_list)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)

    th = threading.Thread(target=httpd.serve_forever, daemon=True)
    th.start()
    try:
        # tiny pause to ensure it's listening on some systems
        time.sleep(0.05)
        host, port = httpd.server_address
        yield host, port
    finally:
        httpd.shutdown()
        httpd.server_close()
        os.chdir(prev_cwd)


# Optional CLI entrypoint — kept minimal and non-blocking for tests that import module.
def main(argv=None):
    import argparse

    ap = argparse.ArgumentParser(description="Download-only HTTP server (for LAN)")
    ap.add_argument("--dir", default=DEFAULT_EXPORT_DIR, help="Base directory")
    ap.add_argument("--file", help="Specific file to serve (single-file mode)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port")
    ap.add_argument("--bind", default="0.0.0.0", help="Bind address")
    ap.add_argument("--list", action="store_true", help="Allow directory listing")
    args = ap.parse_args(argv)

    export_dir = os.path.abspath(os.path.expanduser(args.dir))
    if not os.path.isdir(export_dir):
        print(f"Export directory not found: {export_dir}", file=sys.stderr)
        sys.exit(1)

    serve_file = None
    if args.file:
        serve_file = os.path.abspath(os.path.join(export_dir, args.file))
        if not serve_file.startswith(export_dir) or not os.path.exists(serve_file):
            print(f"serve file must live inside export dir and exist: {serve_file}", file=sys.stderr)
            sys.exit(1)

    print(f"Serving {serve_file or export_dir} on {args.bind}:{args.port}")
    os.chdir(export_dir)

    class Handler(DownloadOnlyHandler):
        base_dir = export_dir
        serve_single_file = serve_file
        allow_dir_list = bool(args.list)

    with ThreadingHTTPServer((args.bind, args.port), Handler) as httpd:
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()


# NOTE: b4 heavy reworks
# Two flip-flopping failing tests (1 and 3)
# #!/usr/bin/env python3
# # File: export_http_server.py
# # silo11writerdeck LAN courier — safe, download-only HTTP server.
# # - Default stash: $HOME
# # - Optional single-file mode via --file
# # - Optional directory listing (off by default)

# from __future__ import annotations

# import argparse
# import http.server
# import os
# import socket
# import socketserver
# import sys
# from urllib.parse import unquote
# from http.server import SimpleHTTPRequestHandler

# DEFAULT_PORT = 8080
# DEFAULT_EXPORT_DIR = os.path.expanduser("~")


# def lan_ips():
#     names = []
#     try:
#         names.append(("mDNS", f"{socket.gethostname()}.local"))
#     except Exception:
#         pass
#     try:
#         s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#         s.connect(("8.8.8.8", 80))
#         names.append(("LAN", s.getsockname()[0]))
#         s.close()
#     except Exception:
#         pass
#     try:
#         addrs = os.popen("hostname -I").read().strip().split()
#         for a in addrs:
#             names.append(("LAN", a))
#     except Exception:
#         pass
#     seen, uniq = set(), []
#     for k, v in names:
#         if v and v not in seen:
#             seen.add(v)
#             uniq.append((k, v))
#     return uniq or [("loopback", "127.0.0.1")]


# class DownloadOnlyHandler(SimpleHTTPRequestHandler):
#     serve_single_file = None
#     allow_dir_list = False
#     base_dir = None

#     def translate_path(self, path):
#         """Resolve path: if serve_single_file is set, always return that file"""
#         if self.serve_single_file:
#             return os.path.abspath(self.serve_single_file)
#         # Otherwise, resolve relative to base_dir or current dir
#         path = super().translate_path(path)
#         if self.base_dir:
#             relpath = os.path.relpath(path, os.getcwd())
#             return os.path.join(self.base_dir, relpath)
#         return path

#     def list_directory(self, path):
#         """Allow directory listing only if allow_dir_list is True"""
#         if not self.allow_dir_list:
#             self.send_error(403, "Directory listing disabled")
#             return None
#         return super().list_directory(path)

#     def send_head(self):
#         """Serve single file with correct headers if serve_single_file is set"""
#         if self.serve_single_file:
#             path = self.translate_path(self.path)
#             if os.path.exists(path) and os.path.isfile(path):
#                 f = open(path, 'rb')
#                 self.send_response(200)
#                 self.send_header("Content-Type", self.guess_type(path))
#                 self.send_header("Content-Length", str(os.path.getsize(path)))
#                 self.send_header("Content-Disposition", f'attachment; filename="{os.path.basename(path)}"')
#                 self.send_header("Cache-Control", "no-store")
#                 self.end_headers()
#                 return f
#             else:
#                 self.send_error(404, "File not found")
#                 return None
#         return super().send_head()



# class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
#     allow_reuse_address = True
#     daemon_threads = True


# def announce_start(port, bind, export_dir, serve_file, allow_list):
#     target = serve_file if serve_file else export_dir
#     print("⛓️  [silo] silo11writerdeck uplink engaged")
#     print(f"📦  stash: {target}")
#     print(f"🔧  port/bind: {port} @ {bind}")
#     mode = f"single-parcel → {os.path.relpath(serve_file, export_dir)}" if serve_file else (
#         "stash-browse disabled (no listing)" if not allow_list else "listing enabled")
#     print(f"🔒 mode: {mode}")
#     print("📡 routes to hand off:")


# def main():
#     ap = argparse.ArgumentParser(
#         description="silo11writerdeck LAN courier (download-only HTTP server). "
#                     "Defaults to $HOME; can serve a single file with --file."
#     )
#     ap.add_argument("--dir", default=DEFAULT_EXPORT_DIR,
#                     help=f"Base directory (default: {DEFAULT_EXPORT_DIR})")
#     ap.add_argument("--file", help="Specific file under --dir to serve (enables single-file mode)")
#     ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port (default: 8080)")
#     ap.add_argument("--bind", default="0.0.0.0",
#                     help="Bind address (0.0.0.0 for LAN, 127.0.0.1 for local)")
#     ap.add_argument("--list", action="store_true", help="Allow directory listing (off by default)")
#     args = ap.parse_args()

#     export_dir = os.path.abspath(os.path.expanduser(args.dir))
#     if not os.path.isdir(export_dir):
#         print(f"⚠️  [silo] stash missing: {export_dir}")
#         print("   Suggestion: create it or pass --dir to point at your stash.")
#         sys.exit(1)

#     # Resolve single-file mode if requested
#     serve_file = None
#     if args.file:
#         serve_file = os.path.abspath(os.path.join(export_dir, args.file))
#         if not serve_file.startswith(export_dir):
#             print("⛔ [silo] file must live inside the stash (export directory).")
#             sys.exit(1)
#         if not os.path.exists(serve_file):
#             print(f"⛔ [silo] target not found inside stash: {serve_file}")
#             sys.exit(1)

#     os.chdir(export_dir)

#     def handler_factory(*h_args, **h_kwargs):
#         h = DownloadOnlyHandler(*h_args, **h_kwargs)
#         # instance attrs so tests or server pick them up
#         h.allow_dir_list = bool(args.list)
#         h.base_dir = export_dir
#         h.serve_single_file = serve_file
#         # also set common alternate names for compatibility
#         h.allow_list = bool(args.list)
#         h.export_dir = export_dir
#         h.serve_file = serve_file
#         h.file = serve_file
#         h.dir = export_dir
#         return h

#     try:
#         with ThreadingTCPServer((args.bind, args.port), handler_factory) as httpd:
#             httpd.base_dir = export_dir
#             httpd.export_dir = export_dir
#             httpd.dir = export_dir
#             httpd.serve_single_file = serve_file
#             httpd.serve_file = serve_file
#             httpd.file = serve_file
#             httpd.allow_dir_list = bool(args.list)
#             httpd.allow_list = bool(args.list)
#             httpd.list = bool(args.list)

#             announce_start(args.port, args.bind, export_dir, serve_file, args.list)

#             urls = []
#             for kind, addr in lan_ips():
#                 host = addr if ":" not in addr else f"[{addr}]"
#                 urls.append((kind, f"http://{host}:{args.port}/"))
#             for kind, u in urls:
#                 tag = "mDNS" if kind.lower() == "mdns" else "LAN"
#                 print(f"   • ({tag}) {u}")
#             if args.bind == "127.0.0.1":
#                 print("   • (tunnel) ssh -L 8080:127.0.0.1:8080 pi@raspberrypi.local")

#             print("🛠️  handler: read-only; Content-Disposition=attachment; Cache-Control=no-store")
#             print("⏹  abort signal: Ctrl+C (hatch will seal)")
#             httpd.serve_forever()
#     except OSError as e:
#         print(f"💥 [silo] uplink failed on {args.bind}:{args.port}: {e}")
#         print("   Remedy: try --port 8081 or check if another courier is already bound.")
#         sys.exit(2)
#     except KeyboardInterrupt:
#         print("\n🛑 [silo] shutdown order received — hatch sealed, radios cold.")
#         sys.exit(0)


# if __name__ == "__main__":
#     main()

# Before reworking to pass tests
# #!/usr/bin/env python3
# # File: export_http_server.py
# # silo11writerdeck LAN courier — safe, download-only HTTP server.
# # - Default stash: $HOME
# # - Optional single-file mode via --file
# # - Optional directory listing (off by default)

# from __future__ import annotations

# import argparse
# import http.server
# import os
# import socket
# import socketserver
# import sys
# from urllib.parse import unquote

# DEFAULT_PORT = 8080
# DEFAULT_EXPORT_DIR = os.path.expanduser("~")


# def lan_ips():
#     names = []
#     # mDNS hint from hostname
#     try:
#         names.append(("mDNS", f"{socket.gethostname()}.local"))
#     except Exception:
#         pass
#     # Cheap LAN IP discovery (no packet actually sent)
#     try:
#         s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
#         s.connect(("8.8.8.8", 80))
#         names.append(("LAN", s.getsockname()[0]))
#         s.close()
#     except Exception:
#         pass
#     # hostname -I
#     try:
#         addrs = os.popen("hostname -I").read().strip().split()
#         for a in addrs:
#             names.append(("LAN", a))
#     except Exception:
#         pass
#     # dedupe, preserve order
#     seen, uniq = set(), []
#     for k, v in names:
#         if v and v not in seen:
#             seen.add(v)
#             uniq.append((k, v))
#     return uniq or [("loopback", "127.0.0.1")]


# class DownloadOnlyHandler(http.server.SimpleHTTPRequestHandler):
#     """Read-only; sets Content-Disposition; optional dir listing."""
#     serve_single_file = None  # absolute path or None
#     allow_dir_list = False
#     base_dir = None

#     def do_GET(self):
#         # Quiet favicon
#         if self.path == "/favicon.ico":
#             self.send_error(404, "Not found")
#             return

#         # Single-file mode: always return the same file
#         if self.serve_single_file:
#             path = self.serve_single_file
#             if not os.path.exists(path):
#                 self.send_error(404, "File not found")
#                 return
#             return self._send_file(path, os.path.basename(path))

#         # Multi-file mode
#         rel = unquote(self.path.lstrip("/"))
#         fs_path = os.path.abspath(os.path.join(self.base_dir, rel))
#         if not fs_path.startswith(self.base_dir):
#             self.send_error(403, "Forbidden")
#             return

#         if os.path.isdir(fs_path):
#             if self.allow_dir_list:
#                 return super().do_GET()
#             index = os.path.join(fs_path, "index.html")
#             if os.path.exists(index):
#                 return super().do_GET()
#             self.send_error(403, "Directory listing disabled")
#             return

#         if not os.path.exists(fs_path):
#             self.send_error(404, "Not found")
#             return

#         return self._send_file(fs_path, os.path.basename(fs_path))

#     def list_directory(self, path):
#         if self.allow_dir_list:
#             return super().list_directory(path)
#         self.send_error(403, "Directory listing disabled")

#     def _send_file(self, path, download_name):
#         ctype = self.guess_type(path) or "application/octet-stream"
#         try:
#             with open(path, "rb") as f:
#                 fs = os.fstat(f.fileno())
#                 self.send_response(200)
#                 self.send_header("Content-Type", ctype)
#                 self.send_header("Content-Length", str(fs.st_size))
#                 self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
#                 self.send_header("Cache-Control", "no-store")
#                 self.end_headers()
#                 self.copyfile(f, self.wfile)
#         except OSError:
#             self.send_error(404, "Not found")


# class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
#     allow_reuse_address = True
#     daemon_threads = True


# def announce_start(port, bind, export_dir, serve_file, allow_list):
#     target = serve_file if serve_file else export_dir
#     print("⛓️  [silo] silo11writerdeck uplink engaged")
#     print(f"📦  stash: {target}")
#     print(f"🔧  port/bind: {port} @ {bind}")
#     mode = f"single-parcel → {os.path.relpath(serve_file, export_dir)}" if serve_file else (
#         "stash-browse disabled (no listing)" if not allow_list else "listing enabled")
#     print(f"🔒 mode: {mode}")
#     print("📡 routes to hand off:")


# def main():
#     ap = argparse.ArgumentParser(
#         description="silo11writerdeck LAN courier (download-only HTTP server). "
#                     "Defaults to $HOME; can serve a single file with --file."
#     )
#     ap.add_argument("--dir", default=DEFAULT_EXPORT_DIR,
#                     help=f"Base directory (default: {DEFAULT_EXPORT_DIR})")
#     ap.add_argument("--file", help="Specific file under --dir to serve (enables single-file mode)")
#     ap.add_argument("--port", type=int, default=DEFAULT_PORT, help="TCP port (default: 8080)")
#     ap.add_argument("--bind", default="0.0.0.0",
#                     help="Bind address (0.0.0.0 for LAN, 127.0.0.1 for local)")
#     ap.add_argument("--list", action="store_true", help="Allow directory listing (off by default)")
#     args = ap.parse_args()

#     export_dir = os.path.abspath(os.path.expanduser(args.dir))
#     if not os.path.isdir(export_dir):
#         print(f"⚠️  [silo] stash missing: {export_dir}")
#         print("   Suggestion: create it or pass --dir to point at your stash.")
#         sys.exit(1)

#     # Resolve single-file mode if requested
#     serve_file = None
#     if args.file:
#         serve_file = os.path.abspath(os.path.join(export_dir, args.file))
#         if not serve_file.startswith(export_dir):
#             print("⛔ [silo] file must live inside the stash (export directory).")
#             sys.exit(1)
#         if not os.path.exists(serve_file):
#             print(f"⛔ [silo] target not found inside stash: {serve_file}")
#             sys.exit(1)

#     os.chdir(export_dir)

#     def handler_factory(*h_args, **h_kwargs):
#         h = DownloadOnlyHandler(*h_args, **h_kwargs)
#         h.allow_dir_list = bool(args.list)
#         h.base_dir = export_dir
#         h.serve_single_file = serve_file
#         return h

#     try:
#         with ThreadingTCPServer((args.bind, args.port), handler_factory) as httpd:
#             announce_start(args.port, args.bind, export_dir, serve_file, args.list)

#             urls = []
#             for kind, addr in lan_ips():
#                 host = addr if ":" not in addr else f"[{addr}]"
#                 urls.append((kind, f"http://{host}:{args.port}/"))
#             for kind, u in urls:
#                 tag = "mDNS" if kind.lower() == "mdns" else "LAN"
#                 print(f"   • ({tag}) {u}")
#             if args.bind == "127.0.0.1":
#                 print("   • (tunnel) ssh -L 8080:127.0.0.1:8080 pi@raspberrypi.local")

#             print("🛠️  handler: read-only; Content-Disposition=attachment; Cache-Control=no-store")
#             print("⏹  abort signal: Ctrl+C (hatch will seal)")
#             httpd.serve_forever()
#     except OSError as e:
#         print(f"💥 [silo] uplink failed on {args.bind}:{args.port}: {e}")
#         print("   Remedy: try --port 8081 or check if another courier is already bound.")
#         sys.exit(2)
#     except KeyboardInterrupt:
#         print("\n🛑 [silo] shutdown order received — hatch sealed, radios cold.")
#         sys.exit(0)


# if __name__ == "__main__":
#     main()
