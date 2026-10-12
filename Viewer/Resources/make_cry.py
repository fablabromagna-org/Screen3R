#!/usr/bin/env python3
"""Synthesises cry.wav: a short (about 2.3 s) baby cry, made from scratch (no recording),
so it is ours to publish under the GNU GPL (v3 or later) like the rest of the project.

    pip install numpy scipy && python3 Viewer/Resources/make_cry.py

How: a glottal source built from harmonics (additive synthesis) whose pitch follows a cry
melody (rise, hold, fall), shaped by the formants of an infant's short vocal tract, with
jitter, shimmer, vibrato and a little breath noise; between the cries, a short noisy gasp.
"""
import os
import wave

import numpy as np
from scipy.signal import butter, lfilter, sosfilt

RATE = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)   # fixed seed: the same file every time


def smooth_noise(n, cutoff_hz, scale):
    """Slowly varying random curve (for jitter, shimmer, drift)."""
    b, a = butter(2, cutoff_hz / (RATE / 2))
    x = lfilter(b, a, rng.standard_normal(n))
    return x / (np.std(x) + 1e-9) * scale


def resonance(f, centre, bandwidth):
    """Magnitude of a two-pole resonator, 1 at 0 Hz."""
    return centre ** 2 / np.sqrt((centre ** 2 - f ** 2) ** 2 + (bandwidth * f) ** 2)


def envelope(n, attack, release):
    t = np.arange(n) / RATE
    dur = n / RATE
    env = np.minimum(1, t / attack) * np.minimum(1, (dur - t) / release)
    return np.clip(env, 0, 1) ** 1.5


def voiced(duration, f0_curve, formant_curve, loudness=1.0, rough=None, breath=0.06):
    """One phonation. f0_curve(x) and formant_curve(x) take x = 0…1 (position in the cry);
    formant_curve returns [(centre, bandwidth), …]. rough = (start, end) where the voice
    breaks into period doubling, as real cries often do at their loudest."""
    n = int(duration * RATE)
    x = np.linspace(0, 1, n)
    f0 = f0_curve(x)
    f0 = f0 * (1 + 0.025 * np.sin(2 * np.pi * 6.0 * np.arange(n) / RATE + rng.uniform(0, 6)))   # vibrato
    f0 = f0 * (1 + smooth_noise(n, 40, 0.012))                                                     # jitter
    phase = 2 * np.pi * np.cumsum(f0) / RATE
    shimmer = 1 + smooth_noise(n, 30, 0.08)

    out = np.zeros(n)
    block = 128
    for start in range(0, n, block):
        end = min(n, start + block)
        xm = x[(start + end) // 2]
        fm = f0[(start + end) // 2]
        formants = formant_curve(xm)
        k = np.arange(1, int(9000 / fm) + 1)
        freqs = k * fm
        amp = k ** -1.0                                   # pressed, tense voice: flat-ish spectrum
        for centre, bw in formants:
            amp = amp * resonance(freqs, centre, bw)
        seg = np.sin(np.outer(phase[start:end], k)) @ amp
        if rough and rough[0] <= xm <= rough[1]:
            # Subharmonic (period doubling): the "rough" quality of a cry at full force.
            sub = np.sin(np.outer(phase[start:end], k - 0.5)) @ (amp * 0.45)
            seg = seg + sub
        out[start:end] = seg
    out /= np.max(np.abs(out)) + 1e-9

    # Breath: noise through the same vocal tract.
    noise = rng.standard_normal(n)
    sos = butter(2, [900 / (RATE / 2), 6000 / (RATE / 2)], btype="band", output="sos")
    noise = sosfilt(sos, noise)
    noise /= np.max(np.abs(noise)) + 1e-9
    sig = out * shimmer + breath * noise
    return sig * envelope(n, 0.045, 0.12) * loudness


def gasp(duration, loudness=0.35):
    """Inhalation between cries: short, noisy, with a squeaky rising pitch."""
    n = int(duration * RATE)
    t = np.arange(n) / RATE
    f = np.linspace(650, 1150, n)
    tone = np.sin(2 * np.pi * np.cumsum(f) / RATE) * 0.35 + np.sin(4 * np.pi * np.cumsum(f) / RATE) * 0.12
    noise = sosfilt(butter(2, [1500 / (RATE / 2), 5000 / (RATE / 2)], btype="band", output="sos"), rng.standard_normal(n))
    noise /= np.max(np.abs(noise)) + 1e-9
    env = np.sin(np.pi * t / t[-1]) ** 2
    return (tone + 0.6 * noise) * env * loudness


def wah_formants(open_at=0.12, f1=1150, f2=2350, f3=4300):
    """'w' (low formants) gliding into an open 'aah' within the first `open_at` of the cry,
    closing a little towards the end."""
    def curve(x):
        o = np.clip(x / open_at, 0, 1) ** 0.7
        close = np.clip((x - 0.85) / 0.15, 0, 1) * 0.25
        a = o * (1 - close)
        return [(500 + (f1 - 500) * a, 160), (1000 + (f2 - 1000) * a, 220), (f3, 350), (5600, 500)]
    return curve


def melody(start, peak, end, peak_at=0.3):
    def curve(x):
        rise = start + (peak - start) * np.clip(x / peak_at, 0, 1) ** 0.6
        fall = peak + (end - peak) * np.clip((x - 0.55) / 0.45, 0, 1) ** 1.6
        return np.where(x < 0.55, rise, fall)
    return curve


def silence(seconds):
    return np.zeros(int(seconds * RATE))


parts = [
    silence(0.03),
    voiced(0.72, melody(360, 560, 420), wah_formants(), loudness=0.85),
    silence(0.04),
    gasp(0.22),
    silence(0.03),
    voiced(0.95, melody(400, 620, 380, peak_at=0.25), wah_formants(open_at=0.1, f1=1200, f2=2450), loudness=1.0,
           rough=(0.32, 0.5)),
    silence(0.05),
    gasp(0.16, loudness=0.25),
    voiced(0.26, melody(470, 500, 380, peak_at=0.4), wah_formants(open_at=0.25, f1=950, f2=2200), loudness=0.5,
           breath=0.1),
    silence(0.08),
]
sig = np.concatenate(parts)

# Small-speaker friendly: no rumble, a gentle top-end roll-off, peaks at -3 dBFS.
sig = sosfilt(butter(2, 180 / (RATE / 2), btype="high", output="sos"), sig)
sig = sosfilt(butter(2, 9000 / (RATE / 2), btype="low", output="sos"), sig)
sig = np.tanh(sig / np.max(np.abs(sig)) * 1.4)
sig = sig / np.max(np.abs(sig)) * 10 ** (-3 / 20)

path = os.path.join(HERE, "cry.wav")
with wave.open(path, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes((sig * 32767).astype("<i2").tobytes())
print(f"wrote {path} ({len(sig) / RATE:.2f} s)")
