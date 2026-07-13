#!/usr/bin/env python3
"""
E2E voice test for TrapBattle (server already running in VM)

Scenario:
- Connect Player1 + Player2
- Start game
- Inject >10s audio from Player1 mic path
- Capture Player2 received audio
- Compute degradation metrics vs original:
    - STOI (intelligibility)
    - PESQ (wideband MOS proxy)
    - SNR (dB)
    - Segmental SNR
    - Correlation
- Save full report + artifacts in:
    c:/work/game/trapbattle/test_report
"""

import os
import json
import time
import shutil
import queue
import pathlib
import datetime
import subprocess
from dataclasses import dataclass

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

# Optional metrics libs
try:
    from pystoi.stoi import stoi
except Exception:
    stoi = None

try:
    from pesq import pesq
except Exception:
    pesq = None


# --------------------------
# CONFIG
# --------------------------
ROOT = pathlib.Path(r"c:/work/game/trapbattle")
REPORT_DIR = ROOT / "test_report"
VOICE_IN = ROOT / "tests" / "assets" / "voice_test.wav"  # must be >10 sec
VOICE_OUT = REPORT_DIR / "voice_test_received.wav"
STEP_LOG = REPORT_DIR / "steps.log"
JSON_REPORT = REPORT_DIR / "voice_quality_report.json"
MD_REPORT = REPORT_DIR / "voice_quality_report.md"

# Godot binaries/scenes (adjust if needed)
GODOT_BIN = os.environ.get("GODOT_BIN", r"godot")
CLIENT_SCENE = ROOT / "scenes" / "Main.tscn"

SERVER_HOST = os.environ.get("TB_SERVER_HOST", "34-155-132-207.nip.io")
PLAYER1_NAME = "E2E_Player1"
PLAYER2_NAME = "E2E_Player2"
TEST_DURATION_SEC = 10.0
TARGET_SR = 24000  # your VOICE_RATE

# NOTE:
# This test assumes you have a test hook in client to:
#   - auto-connect
#   - auto-start game
#   - inject wav into VoiceManager path (Player1)
#   - dump received voice to wav (Player2)
# If not, implement a minimal debug mode in your game launch args.


@dataclass
class Metrics:
    duration_ref: float
    duration_rx: float
    snr_db: float
    seg_snr_db: float
    corr: float
    stoi: float | None
    pesq_wb: float | None
    verdict: str


def log_step(msg: str):
    ts = datetime.datetime.utcnow().isoformat()
    line = f"[{ts}] {msg}"
    print(line)
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    with open(STEP_LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def ensure_voice_input():
    if not VOICE_IN.exists():
        raise FileNotFoundError(
            f"Missing input file: {VOICE_IN}\n"
            "Put a >10 sec wav at tests/assets/voice_test.wav"
        )
    data, sr = sf.read(str(VOICE_IN))
    dur = len(data) / sr
    if dur < TEST_DURATION_SEC:
        raise ValueError(f"voice_test.wav too short: {dur:.2f}s, need >= {TEST_DURATION_SEC}s")
    log_step(f"Input voice found: {VOICE_IN} duration={dur:.2f}s sr={sr}")


def run_client(player_name: str, role: str):
    """
    role: 'sender' or 'receiver'
    Uses launch args consumed by your game debug hooks.
    """
    cmd = [
        GODOT_BIN,
        "--path", str(ROOT),
        str(CLIENT_SCENE),
        "--",
        f"--e2e_voice=1",
        f"--e2e_server={SERVER_HOST}",
        f"--e2e_name={player_name}",
        f"--e2e_role={role}",
        f"--e2e_voice_in={VOICE_IN}",
        f"--e2e_voice_out={VOICE_OUT}",
        f"--e2e_duration={TEST_DURATION_SEC}",
    ]
    log_step(f"Launching {role} client: {' '.join(cmd)}")
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def wait_for_phrase(proc: subprocess.Popen, phrase: str, timeout=120):
    start = time.time()
    while time.time() - start < timeout:
        line = proc.stdout.readline()
        if line:
            log_step(f"CLIENT: {line.strip()}")
            if phrase in line:
                return True
        else:
            time.sleep(0.05)
    return False


def align_and_resample(ref, sr_ref, rx, sr_rx, target_sr=TARGET_SR):
    if sr_ref != target_sr:
        ref = resample_poly(ref, target_sr, sr_ref)
    if sr_rx != target_sr:
        rx = resample_poly(rx, target_sr, sr_rx)

    if ref.ndim > 1:
        ref = np.mean(ref, axis=1)
    if rx.ndim > 1:
        rx = np.mean(rx, axis=1)

    # crude alignment by cross-correlation
    n = min(len(ref), len(rx))
    ref = ref[:n]
    rx = rx[:n]
    corr = np.correlate(rx, ref, mode="full")
    lag = np.argmax(corr) - (n - 1)

    if lag > 0:
        rx = rx[lag:]
        ref = ref[:len(rx)]
    elif lag < 0:
        ref = ref[-lag:]
        rx = rx[:len(ref)]

    n2 = min(len(ref), len(rx))
    return ref[:n2], rx[:n2], target_sr


def compute_metrics(ref, rx, sr) -> Metrics:
    eps = 1e-12
    noise = ref - rx
    snr = 10 * np.log10((np.sum(ref**2) + eps) / (np.sum(noise**2) + eps))

    # segmental SNR
    frame = int(0.02 * sr)
    vals = []
    for i in range(0, len(ref) - frame, frame):
        rs = ref[i:i+frame]
        ns = (ref[i:i+frame] - rx[i:i+frame])
        p_ref = np.sum(rs**2) + eps
        p_ns = np.sum(ns**2) + eps
        vals.append(10 * np.log10(p_ref / p_ns))
    seg_snr = float(np.mean(np.clip(vals, -10, 35))) if vals else float("nan")

    c = np.corrcoef(ref, rx)[0, 1] if len(ref) > 2 else 0.0

    st = None
    if stoi is not None:
        try:
            st = float(stoi(ref, rx, sr, extended=False))
        except Exception:
            st = None

    pq = None
    if pesq is not None:
        try:
            pq = float(pesq(sr, ref, rx, "wb"))
        except Exception:
            pq = None

    verdict = "PASS"
    if snr < 10 or c < 0.75 or (st is not None and st < 0.75):
        verdict = "FAIL"

    return Metrics(
        duration_ref=len(ref)/sr,
        duration_rx=len(rx)/sr,
        snr_db=float(snr),
        seg_snr_db=float(seg_snr),
        corr=float(c),
        stoi=st,
        pesq_wb=pq,
        verdict=verdict,
    )


def write_reports(metrics: Metrics):
    payload = {
        "timestamp_utc": datetime.datetime.utcnow().isoformat(),
        "server_host": SERVER_HOST,
        "input_file": str(VOICE_IN),
        "received_file": str(VOICE_OUT),
        "metrics": metrics.__dict__,
    }
    with open(JSON_REPORT, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)

    md = f"""# Voice E2E Quality Report

- Date (UTC): {payload["timestamp_utc"]}
- Server: `{SERVER_HOST}`
- Input: `{VOICE_IN}`
- Received: `{VOICE_OUT}`

## Metrics
- Duration ref: **{metrics.duration_ref:.2f}s**
- Duration rx: **{metrics.duration_rx:.2f}s**
- SNR: **{metrics.snr_db:.2f} dB**
- Segmental SNR: **{metrics.seg_snr_db:.2f} dB**
- Correlation: **{metrics.corr:.4f}**
- STOI: **{metrics.stoi if metrics.stoi is not None else "N/A"}**
- PESQ WB: **{metrics.pesq_wb if metrics.pesq_wb is not None else "N/A"}**

## Verdict
**{metrics.verdict}**
"""
    with open(MD_REPORT, "w", encoding="utf-8") as f:
        f.write(md)

    log_step(f"Reports written: {JSON_REPORT}, {MD_REPORT}")


def main():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    if STEP_LOG.exists():
        STEP_LOG.unlink()

    log_step("=== E2E voice test start ===")
    ensure_voice_input()

    p2 = run_client(PLAYER2_NAME, "receiver")
    time.sleep(2.0)
    p1 = run_client(PLAYER1_NAME, "sender")

    # These phrases should be printed by your debug hooks
    ok1 = wait_for_phrase(p1, "E2E: connected and in game", timeout=120)
    ok2 = wait_for_phrase(p2, "E2E: connected and in game", timeout=120)
    if not (ok1 and ok2):
        raise RuntimeError("Players failed to connect/start game in time")

    log_step("Both players connected and game started")

    ok_send = wait_for_phrase(p1, "E2E: voice send completed", timeout=180)
    if not ok_send:
        raise RuntimeError("Sender did not complete voice send")

    ok_recv = wait_for_phrase(p2, "E2E: voice receive completed", timeout=180)
    if not ok_recv:
        raise RuntimeError("Receiver did not complete voice capture")

    if not VOICE_OUT.exists():
        raise FileNotFoundError(f"Missing received voice file: {VOICE_OUT}")

    ref, sr_ref = sf.read(str(VOICE_IN))
    rx, sr_rx = sf.read(str(VOICE_OUT))
    ref_a, rx_a, sr = align_and_resample(ref, sr_ref, rx, sr_rx, TARGET_SR)
    m = compute_metrics(ref_a, rx_a, sr)

    write_reports(m)
    log_step(f"Final verdict: {m.verdict}")

    p1.terminate()
    p2.terminate()
    log_step("=== E2E voice test end ===")


if __name__ == "__main__":
    main()
