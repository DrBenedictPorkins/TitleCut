"""Generates the demo kit's background music: a 64 s ambient bed.

Synthesised from scratch (sine pads, a soft pulse, a plucked arpeggio), so
it carries no third-party rights. Writes a 48 kHz stereo WAV.

    uv run --with numpy python -I make_music.py OUT.wav
"""

import sys
import wave

import numpy as np

RATE = 48_000
BPM = 96
BEAT = 60 / BPM
BAR = 4 * BEAT
BARS = 26  # about 65 s

# Am - F - C - G, as MIDI notes.
CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]


def hz(note: float) -> float:
    return 440.0 * 2 ** ((note - 69) / 12)


def envelope(n: int, attack: float, release: float) -> np.ndarray:
    a = max(1, int(attack * RATE))
    r = max(1, int(release * RATE))
    env = np.ones(n)
    env[:a] = np.linspace(0, 1, a)
    env[-r:] *= np.linspace(1, 0, r)
    return env


def pad(chord: list[int], seconds: float) -> np.ndarray:
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for note in chord:
        for detune in (-0.06, 0.06):
            out += np.sin(2 * np.pi * hz(note + detune) * t)
    return out * envelope(n, 0.8, 0.8) / (len(chord) * 2)


def pluck(note: int, seconds: float) -> np.ndarray:
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    tone = np.sin(2 * np.pi * hz(note) * t) + 0.3 * np.sin(4 * np.pi * hz(note) * t)
    return tone * np.exp(-t * 6) * envelope(n, 0.005, 0.05)


def kick(seconds: float) -> np.ndarray:
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    freq = 50 + 70 * np.exp(-t * 30)
    return np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t * 9)


def main(path: str) -> None:
    total = int(BARS * BAR * RATE) + RATE
    left = np.zeros(total)
    right = np.zeros(total)
    for bar in range(BARS):
        chord = CHORDS[bar % len(CHORDS)]
        start = int(bar * BAR * RATE)
        p = pad(chord, BAR + 0.6) * 0.5
        left[start:start + len(p)] += p
        right[start:start + len(p)] += p
        # Pulse from bar 2, arpeggio from bar 4, both out for the last 2 bars.
        if 2 <= bar < BARS - 2:
            for beat in range(4):
                k = kick(0.4) * 0.35
                s = start + int(beat * BEAT * RATE)
                left[s:s + len(k)] += k
                right[s:s + len(k)] += k
        if 4 <= bar < BARS - 2:
            notes = [chord[0] + 12, chord[1] + 12, chord[2] + 12, chord[1] + 12]
            for step in range(8):
                note = notes[step % 4]
                pl = pluck(note, 0.5) * 0.18
                s = start + int(step * BEAT / 2 * RATE)
                # Alternate sides for width.
                (left if step % 2 == 0 else right)[s:s + len(pl)] += pl
                (right if step % 2 == 0 else left)[s:s + len(pl)] += pl * 0.5
    stereo = np.stack([left, right], axis=1)
    stereo *= 0.8 / np.max(np.abs(stereo))
    fade = int(3 * RATE)
    stereo[-fade:] *= np.linspace(1, 0, fade)[:, None]
    data = (stereo * 32767).astype("<i2").tobytes()
    with wave.open(path, "wb") as out:
        out.setnchannels(2)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(data)


if __name__ == "__main__":
    main(sys.argv[1])
