"""
serve.py — HTTPS/HTTP web server for the Godot HTML export.

Usage:
    python serve.py [export_dir] [--port PORT] [--no-browser]
    python serve.py [export_dir] [--port PORT] --cert cert.pem --key key.pem

Examples:
    python serve.py export                              # plain HTTP on port 8080
    python serve.py export --port 8080 --no-browser    # skip auto-open
    python serve.py export --cert cert.pem --key key.pem  # HTTPS (required for remote)

Godot HTML5 exports require:
  1. Cross-Origin-Opener-Policy / Cross-Origin-Embedder-Policy headers (set automatically)
  2. A Secure Context — either localhost OR HTTPS.
     When accessed from a remote IP, HTTPS is mandatory.
     Pass --cert / --key to enable it (self-signed cert is enough).
"""

import argparse
import os
import socket
import ssl
import sys
import webbrowser
from functools import partial
from http.server import HTTPServer, SimpleHTTPRequestHandler


class GodotHandler(SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler + COOP/COEP headers required by Godot exports."""

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy",   "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        super().end_headers()

    def log_message(self, fmt, *args):
        # Guard against log_error calls where args[0] is HTTPStatus, not a string
        if args and isinstance(args[0], str):
            parts = args[0].split()
            if len(parts) >= 2:
                skip_exts = (".png", ".jpg", ".wasm", ".pck", ".js", ".ico")
                if any(parts[1].endswith(e) for e in skip_exts):
                    return
        super().log_message(fmt, *args)


def main():
    parser = argparse.ArgumentParser(description="Serve a Godot HTML export.")
    parser.add_argument(
        "directory",
        nargs="?",
        default=os.path.join("export", "web"),
        help="Directory to serve (default: ./export/web)",
    )
    parser.add_argument("--port", type=int, default=8080, help="Port (default: 8080)")
    parser.add_argument("--no-browser", action="store_true", help="Do not open the browser automatically")
    parser.add_argument("--cert", default=None, help="Path to TLS certificate file (enables HTTPS)")
    parser.add_argument("--key",  default=None, help="Path to TLS private key file (enables HTTPS)")
    args = parser.parse_args()

    export_dir = os.path.abspath(args.directory)
    if not os.path.isdir(export_dir):
        print(f"[ERROR] Directory not found: {export_dir}")
        print("        Export the game from Godot first:")
        print("        Project > Export > HTML5 > Export Project")
        sys.exit(1)

    use_https = bool(args.cert and args.key)

    handler = partial(GodotHandler, directory=export_dir)
    server  = HTTPServer(("0.0.0.0", args.port), handler)

    if use_https:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=args.cert, keyfile=args.key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)

    try:
        local_ip = socket.gethostbyname(socket.gethostname())
    except Exception:
        local_ip = "127.0.0.1"

    scheme = "https" if use_https else "http"
    url    = f"{scheme}://localhost:{args.port}"
    print(f"Serving Godot HTML export from: {export_dir}")
    print(f"Protocol:                        {'HTTPS (secure context ✓)' if use_https else 'HTTP (localhost only)'}")
    print(f"Open in browser:                 {url}")
    print(f"Your local IP (enter in JOIN):   {local_ip}")
    print(f"Game server WebSocket port:      9999  (run trapbattle-server separately)")
    if use_https:
        print("NOTE: Browser will warn about self-signed cert — click 'Advanced > Proceed'.")
    print("Press Ctrl+C to stop.\n")

    if not args.no_browser:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
