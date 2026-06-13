"""
serve.py — local web server for the Godot HTML export.

Usage:
    python serve.py [export_dir] [--port PORT] [--no-browser]

Examples:
    python serve.py                        # serves ./export/web on port 8080
    python serve.py ./export/web           # explicit directory
    python serve.py ./export/web --port 9000
    python serve.py --no-browser           # skip auto-open

Godot HTML exports require SharedArrayBuffer, which browsers only allow when
the page is served with these two headers:
    Cross-Origin-Opener-Policy:   same-origin
    Cross-Origin-Embedder-Policy: require-corp
This script sets both automatically.
"""

import argparse
import os
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
        # Quieter output — only log non-asset requests
        path = args[0].split()[1] if args else ""
        skip_exts = (".png", ".jpg", ".wasm", ".pck", ".js", ".ico")
        if not any(path.endswith(e) for e in skip_exts):
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
    parser.add_argument(
        "--no-browser", action="store_true", help="Do not open the browser automatically"
    )
    args = parser.parse_args()

    export_dir = os.path.abspath(args.directory)
    if not os.path.isdir(export_dir):
        print(f"[ERROR] Directory not found: {export_dir}")
        print("        Export the game from Godot first:")
        print("        Project > Export > HTML5 > Export Project")
        sys.exit(1)

    handler = partial(GodotHandler, directory=export_dir)
    server  = HTTPServer(("0.0.0.0", args.port), handler)

    url = f"http://localhost:{args.port}"
    print(f"Serving Godot HTML export from: {export_dir}")
    print(f"Open in browser:                {url}")
    print("Press Ctrl+C to stop.\n")

    if not args.no_browser:
        webbrowser.open(url)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nServer stopped.")


if __name__ == "__main__":
    main()
