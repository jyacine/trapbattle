#!/usr/bin/env python3
"""
Bidirectional E2E voice test for TrapBattle.

Spins up two symmetric headless Godot peers (voice_peer.gd).  Both peers send
the same test chirp while simultaneously recording what arrives from the partner.
Voice is routed through the live dedicated server.  Quality is measured in both
directions: P1→P2 and P2→P1.

Usage:
    python tests/e2e_voice_test.py

Prerequisites:
    pip install -r tests/requirements.txt

    The dedicated server must be running at 34.155.132.207 (port 443/WSS).
    No other player should be connected to the server during the test.

Outputs (test_report/<timestamp>/):
    voice_test.wav    — original 12-second test chirp (sent by both peers)
    p2_received.wav   — audio captured by P2 (sent by P1)
    p1_received.wav   — audio captured by P1 (sent by P2)
    report.md         — step-by-step log + quality metrics for both directions
"""

import os
import sys
import time
import datetime
import subprocess
import math
import struct

if sys.platform == "win32":
    sys.stdout = open(sys.stdout.fileno(), mode="w", encoding="utf-8", buffering=1, closefd=False)
    sys.stderr = open(sys.stderr.fileno(), mode="w", encoding="utf-8", buffering=1, closefd=False)

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR  = os.path.join(SCRIPT_DIR, "assets")
REPORT_BASE = os.path.join(PROJECT_DIR, "test_report")

GODOT_PATH = r"C:\Users\XDGT0500\Downloads\Godot_v4.6.3-stable_win64.exe"
VOICE_RATE = 24000

PEER_TIMEOUT = 90  # seconds per peer; both wait concurrently

# ── Logging ─────────────────────────────────────────────────────────────────────

_steps: list[dict] = []
_t0 = time.monotonic()


def _log(label: str, status: str, note: str = "", elapsed: float | None = None) -> None:
    entry = {"label": label, "status": status, "note": note,
             "elapsed": elapsed if elapsed is not None else time.monotonic() - _t0}
    _steps.append(entry)
    icon = "✅" if status == "PASS" else ("❌" if status == "FAIL" else "⏳")
    print(f"  {icon} [{entry['elapsed']:6.1f}s]  {label}"
          + (f" — {note}" if note else ""))


# ── Audio helpers ───────────────────────────────────────────────────────────────

def _convert_wav_for_test(src_path: str, dst_path: str, target_rate: int = VOICE_RATE) -> str:
    import wave, array
    with wave.open(src_path, "rb") as wf:
        src_ch, src_rate, src_bits = wf.getnchannels(), wf.getframerate(), wf.getsampwidth() * 8
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)
    if src_bits == 16:
        samples_raw = list(array.array("h", raw))
    elif src_bits == 8:
        samples_raw = [(b - 128) * 256 for b in raw]
    else:
        raise ValueError(f"unsupported bit depth: {src_bits}")
    mono_f = ([(samples_raw[i*2] + samples_raw[i*2+1]) * 0.5 / 32768.0 for i in range(n_frames)]
              if src_ch == 2 else [s / 32768.0 for s in samples_raw])
    if src_rate != target_rate:
        try:
            import numpy as np
            from scipy.signal import resample_poly
            from math import gcd
            g = gcd(target_rate, src_rate)
            mono_f = resample_poly(np.array(mono_f, dtype=np.float32),
                                   target_rate // g, src_rate // g).tolist()
        except ImportError:
            ratio = src_rate / target_rate
            n_out = int(len(mono_f) / ratio)
            mono_f = [mono_f[min(int(i * ratio), len(mono_f)-1)] for i in range(n_out)]
    out_i16 = [max(-32768, min(32767, int(s * 32767))) for s in mono_f]
    _write_wav(dst_path, out_i16, target_rate)
    dur = len(out_i16) / target_rate
    return f"{src_ch}ch {src_rate}Hz {src_bits}bit → mono {target_rate}Hz 16bit  {dur:.1f}s"


def _generate_test_audio(path: str, sample_rate: int = VOICE_RATE, duration: float = 12.0) -> None:
    try:
        import numpy as np
        n = int(sample_rate * duration)
        t = np.linspace(0, duration, n, endpoint=False)
        f0, f1 = 100.0, 4000.0
        k = (f1 - f0) / duration
        phi = 2 * math.pi * (f0 * t + 0.5 * k * t * t)
        sig = (0.50 * np.sin(phi) + 0.25 * np.sin(2 * phi + 0.3)
             + 0.12 * np.sin(3 * phi + 0.7) + 0.06 * np.sin(4 * phi + 1.1))
        fade = int(sample_rate * 0.08)
        sig[:fade]  *= np.linspace(0, 1, fade)
        sig[-fade:] *= np.linspace(1, 0, fade)
        sig = sig / max(np.max(np.abs(sig)), 1e-6) * 0.85
        data_i16 = (sig * 32767).astype(np.int16)
    except ImportError:
        n = int(sample_rate * duration)
        data_i16 = _pure_python_chirp(n, sample_rate, duration)
    _write_wav(path, data_i16, sample_rate)


def _pure_python_chirp(n: int, rate: int, duration: float) -> list[int]:
    f0, f1 = 100.0, 4000.0
    k = (f1 - f0) / duration
    out, fade = [], int(rate * 0.08)
    for i in range(n):
        t = i / rate
        phi = 2 * math.pi * (f0 * t + 0.5 * k * t * t)
        s = 0.50 * math.sin(phi) + 0.25 * math.sin(2 * phi + 0.3)
        env = i / fade if i < fade else (n - i) / fade if i >= n - fade else 1.0
        out.append(max(-32768, min(32767, int(s * env * 0.85 * 32767))))
    return out


def _write_wav(path: str, samples, rate: int) -> None:
    if hasattr(samples, 'tobytes'):
        raw, n = samples.tobytes(), len(samples)
    else:
        raw, n = struct.pack(f"<{len(samples)}h", *samples), len(samples)
    data_len = n * 2
    with open(path, "wb") as f:
        f.write(b"RIFF"); f.write(struct.pack("<I", 36 + data_len))
        f.write(b"WAVE")
        f.write(b"fmt "); f.write(struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16))
        f.write(b"data"); f.write(struct.pack("<I", data_len))
        f.write(raw)


def _read_wav(path: str) -> tuple[int, list]:
    with open(path, "rb") as f:
        hdr = f.read(44)
    rate    = struct.unpack_from("<I", hdr, 24)[0]
    data_len = struct.unpack_from("<I", hdr, 40)[0]
    with open(path, "rb") as f:
        f.seek(44); raw = f.read(data_len)
    n = len(raw) // 2
    return rate, [s / 32768.0 for s in struct.unpack(f"<{n}h", raw[:n * 2])]


# ── Quality analysis ─────────────────────────────────────────────────────────────

def _find_delay(orig: list[float], recv: list[float], max_lag: int = 48000) -> int:
    try:
        import numpy as np
        a = np.array(orig[:max_lag], dtype=np.float64)
        b = np.array(recv[:max_lag + max_lag], dtype=np.float64)
        return int(np.argmax(np.correlate(b, a, mode='valid')))
    except ImportError:
        step, best, best_lag = 1000, -1.0, 0
        for lag in range(0, min(max_lag, len(recv) - len(orig)), step):
            n = min(len(orig), len(recv) - lag)
            dot = sum(orig[i] * recv[lag + i] for i in range(0, n, step))
            if dot > best: best, best_lag = dot, lag
        return best_lag


def _snr_db(signal: list[float], noise: list[float]) -> float:
    n = min(len(signal), len(noise))
    sig_pwr  = sum(s * s for s in signal[:n]) / max(n, 1)
    nois_pwr = sum((signal[i] - noise[i]) ** 2 for i in range(n)) / max(n, 1)
    if nois_pwr < 1e-12: return 99.0
    return 10 * math.log10(max(sig_pwr, 1e-12) / nois_pwr)


def _pearson(a: list[float], b: list[float]) -> float:
    n = min(len(a), len(b))
    if n == 0: return 0.0
    ma, mb = sum(a[:n]) / n, sum(b[:n]) / n
    num = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
    da  = math.sqrt(sum((a[i] - ma) ** 2 for i in range(n)))
    db  = math.sqrt(sum((b[i] - mb) ** 2 for i in range(n)))
    if da < 1e-10 or db < 1e-10: return 0.0
    return num / (da * db)


def _pesq_score(orig: list[float], recv: list[float], rate: int) -> float | None:
    try:
        from pesq import pesq
        import numpy as np
        from scipy.signal import resample_poly
        target = 16000
        o16 = resample_poly(np.array(orig, dtype=np.float32), target, rate)
        r16 = resample_poly(np.array(recv, dtype=np.float32), target, rate)
        n = min(len(o16), len(r16))
        return float(pesq(target, o16[:n], r16[:n], 'wb'))
    except Exception:
        return None


def analyze_quality(orig_path: str, recv_path: str) -> dict:
    if not os.path.exists(recv_path):
        return {"error": "received WAV not found"}
    orig_rate, orig = _read_wav(orig_path)
    recv_rate, recv = _read_wav(recv_path)
    if orig_rate != recv_rate:
        return {"error": f"sample rate mismatch: {orig_rate} vs {recv_rate}"}
    if not recv:
        return {"error": "received WAV is empty"}
    delay    = _find_delay(orig, recv, max_lag=orig_rate * 2)
    delay_ms = delay * 1000.0 / orig_rate
    ao = orig[delay:delay + len(recv)]
    ar = recv[:len(ao)]
    n  = min(len(ao), len(ar))
    ao, ar = ao[:n], ar[:n]
    snr  = _snr_db(ao, ar)
    corr = _pearson(ao, ar)
    pesq = _pesq_score(ao, ar, orig_rate)
    win, lost, total, sil_thresh = 480, 0, 0, 0.02
    for i in range(0, n - win, win):
        orig_rms = math.sqrt(sum(x * x for x in ao[i:i + win]) / win)
        recv_rms = math.sqrt(sum(x * x for x in ar[i:i + win]) / win)
        if orig_rms > sil_thresh:
            total += 1
            if recv_rms < sil_thresh: lost += 1
    return {
        "orig_samples":  len(orig), "recv_samples": len(recv),
        "orig_duration": len(orig) / orig_rate,
        "recv_duration": len(recv) / recv_rate,
        "delay_ms": delay_ms, "snr_db": snr, "correlation": corr,
        "pesq_mos": pesq, "pkt_loss_pct": (lost / max(total, 1)) * 100.0,
        "sample_rate": orig_rate,
    }


# ── Report generation ────────────────────────────────────────────────────────────

def _rating(metric: str, value: float | None) -> str:
    if value is None: return "N/A"
    if metric == "pkt_loss_pct":
        if value <= 0:  return "✅ None"
        if value <= 5:  return "✅ Low"
        if value <= 15: return "⚠️  Moderate"
        return "❌ High"
    thresholds = {
        "snr_db":      [(20, "✅ Excellent"), (10, "⚠️  Acceptable"), (0, "❌ Poor")],
        "correlation": [(0.90, "✅ Excellent"), (0.70, "⚠️  Acceptable"), (-1, "❌ Poor")],
        "pesq_mos":    [(3.5, "✅ Excellent"), (3.0, "✅ Good"), (2.0, "⚠️  Fair"), (0, "❌ Poor")],
    }
    for threshold, label in thresholds.get(metric, []):
        if value >= threshold: return label
    return "—"


def _overall_pass(m: dict) -> bool:
    if "error" in m: return False
    return (m.get("snr_db", -999) > 10
            and m.get("correlation", 0) > 0.60
            and m.get("pkt_loss_pct", 100) < 20)


def generate_report(report_dir: str, timestamp: str,
                    metrics_a: dict, metrics_b: dict,
                    orig_path: str, p2_recv_path: str, p1_recv_path: str) -> str:
    orig_size   = os.path.getsize(orig_path)     if os.path.exists(orig_path)     else 0
    p2_rx_size  = os.path.getsize(p2_recv_path)  if os.path.exists(p2_recv_path)  else 0
    p1_rx_size  = os.path.getsize(p1_recv_path)  if os.path.exists(p1_recv_path)  else 0
    both_pass   = _overall_pass(metrics_a) and _overall_pass(metrics_b)
    verdict     = "✅ PASS" if both_pass else "❌ FAIL"

    lines = [
        "# TrapBattle Voice E2E Test Report",
        "",
        f"**Generated:** {timestamp}  ",
        f"**Server:** `wss://34-155-132-207.nip.io`  ",
        f"**Mode:** Bidirectional (P1 ⇄ P2)  ",
        f"**Result:** {verdict}",
        "", "---", "",
        "## Test steps", "",
        "| Step | Status | Elapsed | Notes |",
        "|------|--------|---------|-------|",
    ]
    for s in _steps:
        icon = "✅" if s["status"] == "PASS" else ("❌" if s["status"] == "FAIL" else "⏳")
        lines.append(f"| {s['label']} | {icon} {s['status']} | {s['elapsed']:.1f}s | {s['note']} |")

    lines += [
        "", "---", "",
        "## Audio files", "",
        "| File | Size | Duration | Description |",
        "|------|------|----------|-------------|",
        f"| `voice_test.wav` | {orig_size//1024} KB"
          f" | {metrics_a.get('orig_duration', 0):.1f}s | Original chirp (sent by both peers) |",
        f"| `p2_received.wav` | {p2_rx_size//1024} KB"
          f" | {metrics_a.get('recv_duration', 0):.1f}s | Recorded by P2 ← received from P1 |",
        f"| `p1_received.wav` | {p1_rx_size//1024} KB"
          f" | {metrics_b.get('recv_duration', 0):.1f}s | Recorded by P1 ← received from P2 |",
        "", "---", "",
        "## Quality metrics", "",
        "| Metric | P1 → P2 | P2 → P1 |",
        "|--------|---------|---------|",
    ]

    def _row(label: str, key: str, fmt) -> str:
        va = metrics_a.get(key)
        vb = metrics_b.get(key)
        sa = fmt(va) if va is not None else "—"
        sb = fmt(vb) if vb is not None else "—"
        ra = _rating(key, va) if va is not None else ""
        rb = _rating(key, vb) if vb is not None else ""
        return f"| {label} | {sa} {ra} | {sb} {rb} |"

    if "error" in metrics_a or "error" in metrics_b:
        ea = metrics_a.get("error", "")
        eb = metrics_b.get("error", "")
        lines.append(f"| Error | `{ea}` | `{eb}` |")
    else:
        lines += [
            _row("SNR",              "snr_db",       lambda v: f"{v:.1f} dB"),
            _row("Pearson corr.",    "correlation",  lambda v: f"{v:.3f}"),
            _row("PESQ MOS",         "pesq_mos",     lambda v: f"{v:.2f}" if v else "—"),
            _row("Packet loss",      "pkt_loss_pct", lambda v: f"{v:.1f}%"),
            _row("Network delay",    "delay_ms",     lambda v: f"{v:.0f} ms"),
        ]

    lines += [
        "", "---", "",
        "## Overall assessment", "",
        f"**{verdict}**", "",
        "> Both directions must have SNR > 10 dB, correlation > 0.60, and packet loss < 20 %.",
        "",
    ]
    report = "\n".join(lines)
    report_path = os.path.join(report_dir, "report.md")
    with open(report_path, "w", encoding="utf-8") as f:
        f.write(report)
    return report_path


# ── Main orchestrator ────────────────────────────────────────────────────────────

def main() -> int:
    global _t0
    _t0 = time.monotonic()

    timestamp  = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    report_dir = os.path.join(REPORT_BASE, timestamp)
    os.makedirs(report_dir, exist_ok=True)

    print(f"\n{'='*60}")
    print(f"  TrapBattle Voice E2E Test  (bidirectional)")
    print(f"  {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Report → {report_dir}")
    print(f"{'='*60}\n")

    # ── Step 1: check Godot binary ────────────────────────────────────────────────
    if not os.path.exists(GODOT_PATH):
        _log("Godot binary", "FAIL", f"not found at {GODOT_PATH}")
        return _fail_report(report_dir, timestamp)
    _log("Godot binary", "PASS", GODOT_PATH)

    # ── Step 2: prepare test audio ────────────────────────────────────────────────
    assets_wav = os.path.join(ASSETS_DIR, "voice_test.wav")
    orig_path  = os.path.join(report_dir, "voice_test.wav")

    try:
        if os.path.isfile(assets_wav):
            desc = _convert_wav_for_test(assets_wav, orig_path, VOICE_RATE)
            size_kb = os.path.getsize(orig_path) // 1024
            _log("Prepare voice input", "PASS", f"{desc} — {size_kb} KB → voice_test.wav")
        else:
            _generate_test_audio(orig_path, VOICE_RATE, 12.0)
            size_kb = os.path.getsize(orig_path) // 1024
            _log("Generate test audio", "PASS", f"12s chirp at {VOICE_RATE} Hz — {size_kb} KB")
    except Exception as e:
        _log("Prepare voice input", "FAIL", str(e))
        return _fail_report(report_dir, timestamp)

    # P2 records what P1 sends; P1 records what P2 sends.
    p2_recv_path = os.path.join(report_dir, "p2_received.wav")
    p1_recv_path = os.path.join(report_dir, "p1_received.wav")

    godot_base = [GODOT_PATH, "--headless", "--path", PROJECT_DIR]
    print()

    import tempfile
    p1_appdata = tempfile.mkdtemp(prefix="trapbattle_p1_")
    p2_appdata = tempfile.mkdtemp(prefix="trapbattle_p2_")
    p1_env = {**os.environ, "APPDATA": p1_appdata}
    p2_env = {**os.environ, "APPDATA": p2_appdata}

    p1_log_path = os.path.join(report_dir, "p1.log")
    p2_log_path = os.path.join(report_dir, "p2.log")
    p1_log_f = open(p1_log_path, "w", encoding="utf-8")
    p2_log_f = open(p2_log_path, "w", encoding="utf-8")

    # ── Step 3: start P1 (captain) ────────────────────────────────────────────────
    p1_proc = subprocess.Popen(
        godot_base + ["--script", "res://tests/voice_peer.gd",
                      "--", f"input={orig_path}", f"output={p1_recv_path}", "captain"],
        stdout=p1_log_f, stderr=subprocess.STDOUT, env=p1_env,
    )
    _log("Start P1 (captain)", "PASS", f"PID {p1_proc.pid}")

    time.sleep(5.0)  # P1 enters lobby first; P2 joins after

    # ── Step 4: start P2 ─────────────────────────────────────────────────────────
    p2_proc = subprocess.Popen(
        godot_base + ["--script", "res://tests/voice_peer.gd",
                      "--", f"input={orig_path}", f"output={p2_recv_path}"],
        stdout=p2_log_f, stderr=subprocess.STDOUT, env=p2_env,
    )
    _log("Start P2", "PASS", f"PID {p2_proc.pid}")

    # ── Step 5: wait for both peers to finish ─────────────────────────────────────
    p1_ok, p2_ok = _wait_procs([p1_proc, p2_proc], PEER_TIMEOUT, ["[p1]", "[p2]"])
    p1_log_f.close()
    p2_log_f.close()

    p1_rx_kb = os.path.getsize(p1_recv_path) // 1024 if os.path.exists(p1_recv_path) else 0
    p2_rx_kb = os.path.getsize(p2_recv_path) // 1024 if os.path.exists(p2_recv_path) else 0
    _log("Voice exchange", "PASS" if (p1_ok and p2_ok) else "FAIL",
         f"p1 exit={p1_proc.returncode}  p2 exit={p2_proc.returncode}"
         f"  p1_received={p1_rx_kb} KB  p2_received={p2_rx_kb} KB")

    _dump_godot_log(_read_file(p1_log_path), prefix="  [p1]")
    _dump_godot_log(_read_file(p2_log_path), prefix="  [p2]")

    # ── Step 6: quality analysis for both directions ──────────────────────────────
    print()
    metrics_a = analyze_quality(orig_path, p2_recv_path)   # P1 → P2
    metrics_b = analyze_quality(orig_path, p1_recv_path)   # P2 → P1

    def _quality_note(m: dict, direction: str) -> str:
        if "error" in m: return f"{direction}: {m['error']}"
        return (f"{direction}: SNR={m['snr_db']:.1f}dB "
                f"corr={m['correlation']:.3f} loss={m['pkt_loss_pct']:.1f}%")

    note_a = _quality_note(metrics_a, "P1→P2")
    note_b = _quality_note(metrics_b, "P2→P1")
    both_pass = _overall_pass(metrics_a) and _overall_pass(metrics_b)
    _log("Quality analysis", "PASS" if both_pass else "FAIL", f"{note_a}  |  {note_b}")

    # ── Step 7: write report ──────────────────────────────────────────────────────
    report_path = generate_report(report_dir, timestamp,
                                  metrics_a, metrics_b,
                                  orig_path, p2_recv_path, p1_recv_path)
    print(f"\n  Report: {report_path}")

    overall = both_pass and p1_ok and p2_ok
    print(f"\n{'='*60}")
    print(f"  RESULT: {'✅ PASS' if overall else '❌ FAIL'}")
    print(f"{'='*60}\n")
    return 0 if overall else 1


def _wait_procs(procs: list, timeout: float, tags: list) -> list[bool]:
    """Poll all processes concurrently; kill stragglers after timeout."""
    deadline = time.monotonic() + timeout
    results  = [None] * len(procs)
    while time.monotonic() < deadline:
        for i, proc in enumerate(procs):
            if results[i] is None and proc.poll() is not None:
                results[i] = (proc.returncode == 0)
        if all(r is not None for r in results):
            return results
        time.sleep(0.25)
    for i, (proc, tag) in enumerate(zip(procs, tags)):
        if results[i] is None:
            print(f"  ⚠️  {tag} did not finish within {timeout}s — killing")
            proc.kill(); proc.wait()
            results[i] = False
    return results


def _read_file(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f: return f.read()
    except Exception: return ""


def _dump_godot_log(text: str, prefix: str = "") -> None:
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("Godot Engine "):
            print(f"{prefix} {line}")


def _fail_report(report_dir: str, timestamp: str) -> int:
    m = {"error": "test did not complete"}
    op = os.path.join(report_dir, "voice_test.wav")
    generate_report(report_dir, timestamp, m, m, op,
                    os.path.join(report_dir, "p2_received.wav"),
                    os.path.join(report_dir, "p1_received.wav"))
    return 1


if __name__ == "__main__":
    sys.exit(main())
