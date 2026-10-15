#!/usr/bin/env python3
"""Synthesise the vehicle sound effects (no recordings, no licensing questions): 22,050 Hz, 16-bit mono WAV
in sounds/, embedded by nmlc through sound() in the generated NML.

    python3 tools/make_sounds.py

Sounds:
    jet_takeoff.wav       twin-engine airliner takeoff roll (whine + rising broadband roar)
    jet_takeoff_big.wav   wide-body / four-engine takeoff, deeper and longer
    concorde_takeoff.wav  reheat: crackling, distorted roar
    touchdown.wav         tyre screech and thump
    shinkansen_depart.wav three-note departure chime (original melody, not a railway's jingle)
    maglev_depart.wav     rising electromagnetic hum with a soft hiss
"""
from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

SR = 22050
OUT = Path(__file__).resolve().parents[1] / "sounds"
rng = np.random.default_rng(20261015)


def t(seconds: float) -> np.ndarray:
    return np.arange(int(SR * seconds)) / SR


def noise(seconds: float) -> np.ndarray:
    return rng.standard_normal(int(SR * seconds))


def shape(x: np.ndarray, spectrum) -> np.ndarray:
    """Multiply the spectrum by spectrum(f) (f in Hz) and return the real signal."""
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return np.fft.irfft(spec * spectrum(f), n=len(x))


def bandpass(x, lo, hi, tilt=0.0):
    def spectrum(f):
        g = np.where((f >= lo) & (f <= hi), 1.0, 0.0)
        soft = np.exp(-((np.maximum(lo - f, 0) / (lo * 0.4 + 1)) ** 2)) * np.exp(-((np.maximum(f - hi, 0) / (hi * 0.25 + 1)) ** 2))
        return np.maximum(g, soft) * np.power(np.maximum(f, 1.0) / lo, tilt)
    return shape(x, spectrum)


def env(n: int, attack: float, hold: float, release: float, curve: float = 1.0) -> np.ndarray:
    a, r = int(SR * attack), int(SR * release)
    h = max(n - a - r, 0)
    e = np.concatenate([np.linspace(0, 1, a) ** curve, np.ones(h), np.linspace(1, 0, r) ** 1.5])
    return e[:n] if len(e) >= n else np.pad(e, (0, n - len(e)))


def normalise(x: np.ndarray, peak: float = 0.9) -> np.ndarray:
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def write(name: str, x: np.ndarray) -> None:
    data = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(OUT / name), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"wrote sounds/{name} ({len(x) / SR:.1f} s)")


def jet(seconds: float, low: float, high: float, whine: tuple[float, float], big: bool) -> np.ndarray:
    n = int(SR * seconds)
    tt = t(seconds)
    rumble = bandpass(noise(seconds), low, low * 6, tilt=-0.7)
    hiss = bandpass(noise(seconds), high * 0.4, high * 3, tilt=-0.3)
    # The roar builds up: rumble first, hiss grows as the engines spool up.
    spool = np.clip(tt / (seconds * 0.45), 0, 1) ** 1.6
    body = rumble * (0.9 if big else 0.7) + hiss * (0.25 + 0.55 * spool)
    f0, f1 = whine
    freq = f0 + (f1 - f0) * np.clip(tt / (seconds * 0.6), 0, 1) ** 0.8
    phase = 2 * np.pi * np.cumsum(freq) / SR
    tone = (np.sin(phase) + 0.5 * np.sin(2 * phase + 0.3) + 0.25 * np.sin(3 * phase)) * (0.05 + 0.08 * spool)
    tone *= 1 + 0.08 * np.sin(2 * np.pi * 7 * tt)
    x = (body + tone) * env(n, 0.6, 0.0, seconds * 0.3, curve=1.4)
    return normalise(np.tanh(x * (1.6 if big else 1.2)))


def concorde(seconds: float = 4.0) -> np.ndarray:
    n = int(SR * seconds)
    tt = t(seconds)
    roar = bandpass(noise(seconds), 35, 500, tilt=-0.6)
    crackle_rate = bandpass(noise(seconds), 20, 70) * 2.2
    crackle = roar * (1 + np.clip(crackle_rate, -0.9, 3.0))
    hiss = bandpass(noise(seconds), 600, 5000, tilt=-0.5) * 0.35
    spool = np.clip(tt / (seconds * 0.5), 0, 1) ** 1.3
    x = (crackle * (0.5 + 0.5 * spool) + hiss * (0.3 + 0.7 * spool)) * env(n, 0.5, 0.0, seconds * 0.25, curve=1.3)
    return normalise(np.tanh(x * 2.2))


def touchdown(seconds: float = 1.0) -> np.ndarray:
    n = int(SR * seconds)
    tt = t(seconds)
    screech = bandpass(noise(seconds), 1300, 2600, tilt=0.3) * np.exp(-tt * 5.5)
    screech *= 1 + 0.4 * np.sin(2 * np.pi * 180 * tt)                # chattering
    thump = np.sin(2 * np.pi * 70 * tt) * np.exp(-tt * 12) * 0.9
    rumble = bandpass(noise(seconds), 60, 400) * np.exp(-tt * 4) * 0.4
    x = (screech * 0.8 + thump + rumble) * env(n, 0.01, 0.0, 0.3)
    return normalise(x)


def chime(notes: list[float], note_len: float = 0.28, tail: float = 0.9) -> np.ndarray:
    total = note_len * len(notes) + tail
    n = int(SR * total)
    x = np.zeros(n)
    for k, f in enumerate(notes):
        start = int(SR * note_len * k)
        m = n - start
        tt = t(m / SR)[:m]
        tone = (np.sin(2 * np.pi * f * tt) + 0.35 * np.sin(2 * np.pi * 2 * f * tt) + 0.12 * np.sin(2 * np.pi * 3 * f * tt))
        tone *= np.exp(-tt * 2.6) * np.minimum(tt / 0.012, 1.0)
        x[start:start + m] += tone
    return normalise(x, 0.8)


def maglev(seconds: float = 2.0) -> np.ndarray:
    n = int(SR * seconds)
    tt = t(seconds)
    freq = 55 + 150 * np.clip(tt / (seconds * 0.8), 0, 1) ** 1.2
    phase = 2 * np.pi * np.cumsum(freq) / SR
    hum = np.sin(phase) + 0.5 * np.sin(2 * phase) + 0.3 * np.sin(3 * phase) + 0.15 * np.sin(4 * phase)
    hum *= 1 + 0.15 * np.sin(2 * np.pi * 50 * tt)                      # power-electronics flutter
    hiss = bandpass(noise(seconds), 2000, 6000) * 0.12 * np.clip(tt / seconds, 0, 1)
    x = (hum * 0.6 + hiss) * env(n, 0.25, 0.0, seconds * 0.3)
    return normalise(x, 0.8)


def main() -> None:
    OUT.mkdir(exist_ok=True)
    write("jet_takeoff.wav", jet(3.0, 70, 1800, (900, 2300), big=False))
    write("jet_takeoff_big.wav", jet(3.6, 45, 1400, (650, 1700), big=True))
    write("concorde_takeoff.wav", concorde())
    write("touchdown.wav", touchdown())
    write("shinkansen_depart.wav", chime([659.26, 783.99, 1046.50]))   # E5 G5 C6
    write("maglev_depart.wav", maglev())


if __name__ == "__main__":
    main()
