#!/usr/bin/env python3
"""Find this set's sound effects in audio recorded from a QA game.

    SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE=$PWD/build/qa/audio.raw \\
        python3 tools/ingame/run.py --sound-driver sdl ...
    python3 tools/ingame/audio_check.py build/qa/audio.raw [--start BYTES] [--end BYTES] [--threshold 0.4]

The raw file is what OpenTTD mixed: signed 16-bit stereo at 44100 Hz (the SDL sound driver's default).
Every sounds/*.wav is upsampled the way the OpenTTD mixer does it (sample and hold) and slid over the
recording with a normalised cross-correlation; peaks above the threshold are reported with their time.
"""
import argparse
import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
RATE = 44100


def read_wav(path: Path) -> tuple[np.ndarray, int]:
    b = path.read_bytes()
    assert b[:4] == b"RIFF" and b[8:12] == b"WAVE", path
    pos, rate, data = 12, 0, b""
    while pos + 8 <= len(b):
        cid, size = b[pos:pos + 4], struct.unpack("<I", b[pos + 4:pos + 8])[0]
        if cid == b"fmt ":
            fmt, ch, rate, _, _, bits = struct.unpack("<HHIIHH", b[pos + 8:pos + 24])
            assert (fmt, ch, bits) == (1, 1, 16), path
        elif cid == b"data":
            data = b[pos + 8:pos + 8 + size]
        pos += 8 + size + (size & 1)
    return np.frombuffer(data, dtype="<i2").astype(np.float64), rate


def upsample_hold(x: np.ndarray, rate: int) -> np.ndarray:
    """Sample-and-hold resampling to RATE, like the mixer's fractional stepping."""
    n = int(len(x) * RATE / rate)
    idx = (np.arange(n) * rate // RATE).clip(0, len(x) - 1)
    return x[idx]


def normalised_xcorr(x: np.ndarray, h: np.ndarray) -> np.ndarray:
    """Correlation of h with every window of x, divided by both energies (1.0 = identical shape)."""
    m = len(h)
    h = (h - h.mean()) / (np.linalg.norm(h) + 1e-9)
    n = len(x) - m + 1
    if n <= 0:
        return np.zeros(0)
    size = 1 << int(np.ceil(np.log2(len(x) + m)))
    corr = np.fft.irfft(np.fft.rfft(x, size) * np.conj(np.fft.rfft(h, size)), size)[:n]
    cum = np.concatenate([[0.0], np.cumsum(x * x)])
    energy = cum[m:m + n] - cum[:n]          # energy of each m-sample window
    return corr / (np.sqrt(np.maximum(energy, 0.0)) + 1e-6)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw")
    ap.add_argument("--start", type=int, default=0, help="byte offset in the raw file to start at")
    ap.add_argument("--end", type=int, default=0, help="byte offset to stop at (0 = end of file)")
    ap.add_argument("--threshold", type=float, default=0.4)
    args = ap.parse_args()
    raw = np.fromfile(args.raw, dtype="<i2", offset=args.start & ~3, count=-1 if not args.end else (args.end - args.start) // 2)
    mono = raw.reshape(-1, 2).mean(axis=1)
    print(f"recording: {len(mono) / RATE:.1f} s, peak {np.abs(mono).max():.0f}, "
          f"{(np.abs(mono) > 300).mean() * 100:.1f}% of samples above -40 dBFS")
    for wav in sorted((ROOT / "sounds").glob("*.wav")):
        x, rate = read_wav(wav)
        h = upsample_hold(x, rate)
        c = normalised_xcorr(mono, h)
        hits = []
        i = 0
        while i < len(c):
            if c[i] > args.threshold:
                j = i + int(np.argmax(c[i:i + len(h)]))
                hits.append((j / RATE, c[j]))
                i = j + len(h)
            else:
                i += 1
        best = c.max() if len(c) else 0.0
        where = ", ".join(f"{t:.1f}s ({v:.2f})" for t, v in hits)
        print(f"{wav.name:<24} {len(x) / rate:.1f}s  best {best:.2f}  hits {len(hits)}: {where}")


if __name__ == "__main__":
    main()
