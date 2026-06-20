#!/usr/bin/env python3
"""
E2E voice communication test for TrapBattle.

Spins up two headless Godot processes (sender + receiver), routes voice through
the live dedicated server, then measures audio quality degradation.

Usage:
    python tests/e2e_voice_test.py

Prerequisites:
    pip install -r tests/requirements.txt

    The dedicated server must be running at 172.174.208.254 (port 443/WSS).
    No other player should be connected to the server during the test.

Outputs (test_report/<timestamp>/):
    voice_test.wav       — original 12-second test signal
    voice_received.wav   — audio captured by Player 2
    report.md            — step-by-step log + quality metrics
"""

import os
import sys
import time
import datetime
import subprocess
import math
import struct

# Force UTF-8 output on Windows (avoids cp1252 UnicodeEncodeError for → ✅ etc.)
if sys.platform == "win32":
    sys.stdout = open(sys.stdout.fileno(), mode="w", encoding="utf-8", buffering=1, closefd=False)
    sys.stderr = open(sys.stderr.fileno(), mode="w", encoding="utf-8", buffering=1, closefd=False)

SCRIPT_DIR  = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
ASSETS_DIR = os.path.join(SCRIPT_DIR, "assets")
REPORT_BASE = os.path.join(PROJECT_DIR, "test_report")

GODOT_PATH  = r"C:\Users\XDGT0500\Downloads\Godot_v4.6.3-stable_win64.exe"
VOICE_RATE  = 24000   # must match VoiceManager.VOICE_RATE

# Timeouts (seconds)
SENDER_TIMEOUT   = 70
RECEIVER_TIMEOUT = 80

# ── Logging ─────────────────────────────────────────────────────────────────────

_steps: list[dict] = []

def _log(label: str, status: str, note: str = "", elapsed: float | None = None) -> None:
    entry = {"label": label, "status": status, "note": note,
             "elapsed": elapsed if elapsed is not None else time.monotonic() - _t0}
    _steps.append(entry)
    icon = "✅" if status == "PASS" else ("❌" if status == "FAIL" else "⏳")
    print(f"  {icon} [{entry['elapsed']:6.1f}s]  {label}"
          + (f" — {note}" if note else ""))

_t0 = time.monotonic()

# ── Audio helpers ───────────────────────────────────────────────────────────────

def _convert_wav_for_test(src_path: str, dst_path: str, target_rate: int = VOICE_RATE) -> str:
    """Convert any PCM WAV (stereo/resampled) to mono 16-bit at target_rate.
    Handles WAVs with extra RIFF chunks (LIST metadata, etc.) via Python's wave module.
    Returns a one-line description of what was done."""
    import wave, array, math
    with wave.open(src_path, "rb") as wf:
        src_ch = wf.getnchannels()
        src_rate = wf.getframerate()
        src_bits = wf.getsampwidth() * 8
        n_frames = wf.getnframes()
        raw = wf.readframes(n_frames)

    if src_bits == 16:
        samples_raw = list(array.array("h", raw))
    elif src_bits == 8:
        samples_raw = [(b - 128) * 256 for b in raw]
    else:
        raise ValueError(f"unsupported bit depth: {src_bits}")

    # Stereo → mono
    if src_ch == 2:
        mono_f = [(samples_raw[i*2] + samples_raw[i*2+1]) * 0.5 / 32768.0
                  for i in range(n_frames)]
    else:
        mono_f = [s / 32768.0 for s in samples_raw]

    # Resample if needed
    if src_rate != target_rate:
        try:
            import numpy as np
            from scipy.signal import resample_poly
            from math import gcd
            arr = np.array(mono_f, dtype=np.float32)
            g = gcd(target_rate, src_rate)
            mono_f = resample_poly(arr, target_rate // g, src_rate // g).tolist()
        except ImportError:
            ratio = src_rate / target_rate
            n_out = int(len(mono_f) / ratio)
            mono_f = [mono_f[min(int(i * ratio), len(mono_f)-1)] for i in range(n_out)]

    out_i16 = [max(-32768, min(32767, int(s * 32767))) for s in mono_f]
    _write_wav(dst_path, out_i16, target_rate)
    dur = len(out_i16) / target_rate
    return f"{src_ch}ch {src_rate}Hz {src_bits}bit → mono {target_rate}Hz 16bit  {dur:.1f}s"


def _generate_test_audio(path: str, sample_rate: int = VOICE_RATE, duration: float = 12.0) -> None:
    """Sine-wave chirp swept over the speech band (100 Hz → 4 kHz) plus harmonics."""
    try:
        import numpy as np
        n = int(sample_rate * duration)
        t = np.linspace(0, duration, n, endpoint=False)
        # Chirp instantaneous phase: φ = 2π·(f0·t + k/2·t²)
        f0, f1 = 100.0, 4000.0
        k = (f1 - f0) / duration
        phi = 2 * math.pi * (f0 * t + 0.5 * k * t * t)
        sig = (0.50 * np.sin(phi)
             + 0.25 * np.sin(2 * phi + 0.3)
             + 0.12 * np.sin(3 * phi + 0.7)
             + 0.06 * np.sin(4 * phi + 1.1))
        # Amplitude envelope: fade in/out to avoid clicks
        fade = int(sample_rate * 0.08)
        sig[:fade]  *= np.linspace(0, 1, fade)
        sig[-fade:] *= np.linspace(1, 0, fade)
        sig = sig / max(np.max(np.abs(sig)), 1e-6) * 0.85
        data_i16 = (sig * 32767).astype(np.int16)
    except ImportError:
        # numpy not available: use pure-Python chirp
        n = int(sample_rate * duration)
        data_i16 = _pure_python_chirp(n, sample_rate, duration)

    _write_wav(path, data_i16, sample_rate)


def _pure_python_chirp(n: int, rate: int, duration: float) -> list[int]:
    """Fallback chirp generator without numpy."""
    f0, f1 = 100.0, 4000.0
    k = (f1 - f0) / duration
    out = []
    fade = int(rate * 0.08)
    for i in range(n):
        t = i / rate
        phi = 2 * math.pi * (f0 * t + 0.5 * k * t * t)
        s = 0.50 * math.sin(phi) + 0.25 * math.sin(2 * phi + 0.3)
        env = 1.0
        if i < fade:
            env = i / fade
        elif i >= n - fade:
            env = (n - i) / fade
        s = s * env * 0.85
        out.append(max(-32768, min(32767, int(s * 32767))))
    return out


def _write_wav(path: str, samples, rate: int) -> None:
    """Write mono int16 PCM WAV."""
    if hasattr(samples, 'tobytes'):          # numpy array
        raw = samples.tobytes()
        n = len(samples)
    else:                                     # plain list
        raw = struct.pack(f"<{len(samples)}h", *samples)
        n = len(samples)
    data_len = n * 2
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + data_len))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", data_len))
        f.write(raw)


def _read_wav(path: str) -> tuple[int, list]:
    """Read mono int16 PCM WAV, return (sample_rate, samples_as_list_of_float)."""
    with open(path, "rb") as f:
        hdr = f.read(44)
    rate = struct.unpack_from("<I", hdr, 24)[0]
    data_len = struct.unpack_from("<I", hdr, 40)[0]
    with open(path, "rb") as f:
        f.seek(44)
        raw = f.read(data_len)
    n = len(raw) // 2
    samples = list(struct.unpack(f"<{n}h", raw[:n * 2]))
    floats = [s / 32768.0 for s in samples]
    return rate, floats


# ── Quality analysis ─────────────────────────────────────────────────────────────

def _find_delay(orig: list[float], recv: list[float], max_lag: int = 48000) -> int:
    """Return sample delay of recv relative to orig via cross-correlation (pure Python)."""
    try:
        import numpy as np
        a = np.array(orig[:max_lag], dtype=np.float64)
        b = np.array(recv[:max_lag + max_lag], dtype=np.float64)
        corr = np.correlate(b, a, mode='valid')
        return int(np.argmax(corr))
    except ImportError:
        # Pure-Python fallback: coarse search in 1000-sample steps
        step = 1000
        best, best_lag = -1.0, 0
        for lag in range(0, min(max_lag, len(recv) - len(orig)), step):
            n = min(len(orig), len(recv) - lag)
            dot = sum(orig[i] * recv[lag + i] for i in range(0, n, step))
            if dot > best:
                best, best_lag = dot, lag
        return best_lag


def _snr_db(signal: list[float], noise: list[float]) -> float:
    n = min(len(signal), len(noise))
    sig_pwr  = sum(s * s for s in signal[:n]) / max(n, 1)
    nois_pwr = sum((signal[i] - noise[i]) ** 2 for i in range(n)) / max(n, 1)
    if nois_pwr < 1e-12:
        return 99.0
    return 10 * math.log10(max(sig_pwr, 1e-12) / nois_pwr)


def _pearson(a: list[float], b: list[float]) -> float:
    n = min(len(a), len(b))
    if n == 0:
        return 0.0
    ma = sum(a[:n]) / n
    mb = sum(b[:n]) / n
    num = sum((a[i] - ma) * (b[i] - mb) for i in range(n))
    da  = math.sqrt(sum((a[i] - ma) ** 2 for i in range(n)))
    db  = math.sqrt(sum((b[i] - mb) ** 2 for i in range(n)))
    if da < 1e-10 or db < 1e-10:
        return 0.0
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

    delay = _find_delay(orig, recv, max_lag=orig_rate * 2)
    delay_ms = delay * 1000.0 / orig_rate

    # Align signals
    aligned_o = orig[delay:delay + len(recv)]
    aligned_r = recv[:len(aligned_o)]
    n = min(len(aligned_o), len(aligned_r))
    aligned_o = aligned_o[:n]
    aligned_r = aligned_r[:n]

    snr = _snr_db(aligned_o, aligned_r)
    corr = _pearson(aligned_o, aligned_r)
    pesq = _pesq_score(aligned_o, aligned_r, orig_rate)

    # Estimate packet loss: fraction of received windows that are near-silence
    # while the original is not
    win = 480
    lost = 0
    total = 0
    sil_thresh = 0.02
    for i in range(0, n - win, win):
        orig_rms = math.sqrt(sum(x * x for x in aligned_o[i:i + win]) / win)
        recv_rms = math.sqrt(sum(x * x for x in aligned_r[i:i + win]) / win)
        if orig_rms > sil_thresh:
            total += 1
            if recv_rms < sil_thresh:
                lost += 1
    pkt_loss_pct = (lost / max(total, 1)) * 100.0

    return {
        "orig_samples":   len(orig),
        "recv_samples":   len(recv),
        "orig_duration":  len(orig) / orig_rate,
        "recv_duration":  len(recv) / recv_rate,
        "delay_ms":       delay_ms,
        "snr_db":         snr,
        "correlation":    corr,
        "pesq_mos":       pesq,
        "pkt_loss_pct":   pkt_loss_pct,
        "sample_rate":    orig_rate,
    }


# ── Report generation ────────────────────────────────────────────────────────────

def _rating(metric: str, value: float | None) -> str:
    if value is None:
        return "N/A"
    thresholds = {
        "snr_db":       [(20, "✅ Excellent"), (10, "⚠️  Acceptable"), (0, "❌ Poor")],
        "correlation":  [(0.90, "✅ Excellent"), (0.70, "⚠️  Acceptable"), (-1, "❌ Poor")],
        "pesq_mos":     [(3.5, "✅ Excellent"), (3.0, "✅ Good"), (2.0, "⚠️  Fair"), (0, "❌ Poor")],
        "pkt_loss_pct": [(-1, "✅ 0 %"), (5, "✅ Low"), (15, "⚠️  Moderate"), (100, "❌ High")],
    }
    if metric == "pkt_loss_pct":
        if value <= 0:   return "✅ None"
        if value <= 5:   return "✅ Low"
        if value <= 15:  return "⚠️  Moderate"
        return "❌ High"
    for threshold, label in thresholds.get(metric, []):
        if value >= threshold:
            return label
    return "—"


def _overall_pass(m: dict) -> bool:
    if "error" in m:
        return False
    return (m.get("snr_db", -999) > 10
            and m.get("correlation", 0) > 0.60
            and m.get("pkt_loss_pct", 100) < 20)


def generate_report(report_dir: str, timestamp: str, metrics: dict,
                    orig_path: str, recv_path: str) -> str:
    orig_size = os.path.getsize(orig_path) if os.path.exists(orig_path) else 0
    recv_size = os.path.getsize(recv_path) if os.path.exists(recv_path) else 0

    verdict = "✅ PASS" if _overall_pass(metrics) else "❌ FAIL"

    lines = [
        f"# TrapBattle Voice E2E Test Report",
        f"",
        f"**Generated:** {timestamp}  ",
        f"**Server:** `wss://172-174-208-254.nip.io`  ",
        f"**Result:** {verdict}",
        f"",
        f"---",
        f"",
        f"## Test steps",
        f"",
        f"| Step | Status | Elapsed | Notes |",
        f"|------|--------|---------|-------|",
    ]
    for s in _steps:
        icon = "✅" if s["status"] == "PASS" else ("❌" if s["status"] == "FAIL" else "⏳")
        lines.append(
            f"| {s['label']} | {icon} {s['status']} | {s['elapsed']:.1f}s | {s['note']} |"
        )

    lines += [
        f"",
        f"---",
        f"",
        f"## Audio files",
        f"",
        f"| File | Size | Duration | Format |",
        f"|------|------|----------|--------|",
        f"| `voice_test.wav` | {orig_size // 1024} KB"
          f" | {metrics.get('orig_duration', 0):.1f}s"
          f" | {VOICE_RATE} Hz mono int16 |",
        f"| `voice_received.wav` | {recv_size // 1024} KB"
          f" | {metrics.get('recv_duration', 0):.1f}s"
          f" | {metrics.get('sample_rate', VOICE_RATE)} Hz mono int16 |",
        f"",
        f"---",
        f"",
        f"## Quality metrics",
        f"",
        f"| Metric | Value | Rating |",
        f"|--------|-------|--------|",
    ]

    if "error" in metrics:
        lines.append(f"| Error | `{metrics['error']}` | ❌ |")
    else:
        snr = metrics.get("snr_db")
        corr = metrics.get("correlation")
        pesq = metrics.get("pesq_mos")
        loss = metrics.get("pkt_loss_pct")
        delay = metrics.get("delay_ms")
        lines += [
            f"| SNR (signal-to-noise) | {snr:.1f} dB | {_rating('snr_db', snr)} |",
            f"| Pearson correlation | {corr:.3f} | {_rating('correlation', corr)} |",
            f"| PESQ MOS (wideband) | {f'{pesq:.2f}' if pesq else 'not installed'}"
              f" | {_rating('pesq_mos', pesq)} |",
            f"| Estimated packet loss | {loss:.1f}% | {_rating('pkt_loss_pct', loss)} |",
            f"| Network delay (alignment) | {delay:.0f} ms | {'✅' if delay < 500 else '⚠️ '} |",
        ]

    lines += [
        f"",
        f"---",
        f"",
        f"## Overall assessment",
        f"",
        f"**{verdict}**",
        f"",
        f"> SNR > 10 dB, correlation > 0.60, and packet loss < 20 % are required to pass.",
        f"",
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

    timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    report_dir = os.path.join(REPORT_BASE, timestamp)
    
    os.makedirs(report_dir, exist_ok=True)
    print(f"\n{'='*60}")
    print(f"  TrapBattle Voice E2E Test")
    print(f"  {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Report → {report_dir}")
    print(f"{'='*60}\n")

    # ── Step 1: check Godot binary ───────────────────────────────────────────────
    if not os.path.exists(GODOT_PATH):
        _log("Godot binary", "FAIL", f"not found at {GODOT_PATH}")
        _finalize_report(report_dir, timestamp)
        return 1
    _log("Godot binary", "PASS", GODOT_PATH)

    # ── Step 2: prepare test audio ───────────────────────────────────────────────
    assets_wav = os.path.join(ASSETS_DIR, "voice_test.wav")
    orig_path  = os.path.join(report_dir, "voice_test.wav")   # always mono 24kHz 16-bit
    recv_path  = os.path.join(report_dir, "voice_received.wav")
    status_path = os.path.join(report_dir, "sender_done.txt")

    try:
        if os.path.isfile(assets_wav):
            desc = _convert_wav_for_test(assets_wav, orig_path, VOICE_RATE)
            size_kb = os.path.getsize(orig_path) // 1024
            _log("Prepare voice input", "PASS", f"{desc} — {size_kb} KB → voice_test.wav")
        else:
            _generate_test_audio(orig_path, VOICE_RATE, 12.0)
            size_kb = os.path.getsize(orig_path) // 1024
            _log("Generate test audio", "PASS",
                 f"12s chirp at {VOICE_RATE} Hz — {size_kb} KB → voice_test.wav")
    except Exception as e:
        _log("Prepare voice input", "FAIL", str(e))
        _finalize_report(report_dir, timestamp)
        return 1

    godot_base = [GODOT_PATH, "--headless", "--path", PROJECT_DIR]
    print()

    # Each Godot process must have its own user-data directory (user://).
    # Two instances sharing the same --path hold a lock on the project's user-data
    # folder; whichever starts second stalls until the first exits — which is why
    # the receiver never connected while the sender was alive.
    # Redirecting APPDATA (Windows) makes each instance write to its own temp dir.
    import tempfile
    send_appdata = tempfile.mkdtemp(prefix="trapbattle_sender_")
    recv_appdata = tempfile.mkdtemp(prefix="trapbattle_receiver_")
    send_env = {**os.environ, "APPDATA": send_appdata}
    recv_env = {**os.environ, "APPDATA": recv_appdata}

    send_log_path = os.path.join(report_dir, "sender.log")
    recv_log_path = os.path.join(report_dir, "receiver.log")
    send_log = open(send_log_path, "w", encoding="utf-8")
    recv_log = open(recv_log_path, "w", encoding="utf-8")

    # ── Step 3: start receiver first so it's waiting in the lobby ─────────────────
    recv_proc = subprocess.Popen(
        godot_base + ["--script", "res://tests/voice_receiver.gd",
                      "--", f"output={recv_path}"],
        stdout=recv_log, stderr=subprocess.STDOUT, env=recv_env
    )
    _log("Start Player 2 (receiver)", "PASS", f"PID {recv_proc.pid}")

    # Give the receiver a 5 s head-start to load, connect, and land in the lobby.
    time.sleep(5.0)

    # ── Step 4: start sender (becomes captain = requests game start) ──────────────
    send_proc = subprocess.Popen(
        godot_base + ["--script", "res://tests/voice_sender.gd",
                      "--", f"input={orig_path}"],
        stdout=send_log, stderr=subprocess.STDOUT, env=send_env
    )
    _log("Start Player 1 (sender)", "PASS", f"PID {send_proc.pid} — captain")

    # ── Step 5: wait for sender to finish (polling, both pipes drain to files) ────
    sender_ok = _wait_proc(send_proc, SENDER_TIMEOUT, "[sender]")
    _log("Voice transmission", "PASS" if sender_ok else "FAIL",
         f"exit={send_proc.returncode}"
         + (f" — {_read_status(status_path)}"
            if os.path.exists(status_path) else ""))

    # Give the receiver a moment to flush its last packets before it self-finishes.
    # ── Step 6: wait for receiver to finish ──────────────────────────────────────
    recv_ok = _wait_proc(recv_proc, RECEIVER_TIMEOUT, "[receiver]")
    send_log.close()
    recv_log.close()
    recv_size = os.path.getsize(recv_path) if os.path.exists(recv_path) else 0
    _log("Voice received & saved", "PASS" if recv_ok else "FAIL",
         f"exit={recv_proc.returncode}  voice_received.wav={recv_size // 1024} KB")

    # Echo the Godot logs for visibility
    _dump_godot_log(_read_file(send_log_path), prefix="  [sender]")
    _dump_godot_log(_read_file(recv_log_path), prefix="  [receiver]")

    # ── Step 7: quality analysis ─────────────────────────────────────────────────
    print()
    metrics = analyze_quality(orig_path, recv_path)
    if "error" in metrics:
        _log("Quality analysis", "FAIL", metrics["error"])
    else:
        snr_str  = f"SNR={metrics['snr_db']:.1f}dB"
        corr_str = f"corr={metrics['correlation']:.3f}"
        loss_str = f"loss={metrics['pkt_loss_pct']:.1f}%"
        _log("Quality analysis", "PASS", f"{snr_str}  {corr_str}  {loss_str}")

    # ── Step 8: write report ─────────────────────────────────────────────────────
    report_path = _finalize_report(report_dir, timestamp, metrics, orig_path, recv_path)
    print(f"\n  Report: {report_path}")

    overall = _overall_pass(metrics) and sender_ok and recv_ok
    print(f"\n{'='*60}")
    print(f"  RESULT: {'✅ PASS' if overall else '❌ FAIL'}")
    print(f"{'='*60}\n")
    return 0 if overall else 1


def _wait_proc(proc: subprocess.Popen, timeout: float, tag: str) -> bool:
    """Poll for exit (output already streams to its own file). True if exit code 0."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return proc.returncode == 0
        time.sleep(0.25)
    print(f"  ⚠️  {tag} did not finish within {timeout}s — killing")
    proc.kill()
    proc.wait()
    return False


def _read_file(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""


def _read_status(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip().replace("\n", " ")
    except Exception:
        return "—"


def _dump_godot_log(text: str, prefix: str = "") -> None:
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("Godot Engine "):
            print(f"{prefix} {line}")


def _finalize_report(report_dir, timestamp, metrics=None, orig_path=None, recv_path=None):
    m  = metrics  if metrics   is not None else {"error": "test did not complete"}
    op = orig_path if orig_path is not None else os.path.join(report_dir, "voice_test.wav")
    rp = recv_path if recv_path is not None else os.path.join(report_dir, "voice_received.wav")
    return generate_report(report_dir, timestamp, m, op, rp)


if __name__ == "__main__":
    sys.exit(main())
