"""Renders the Operator sound language to WAV files. Pure stdlib.

Each sound is a list of notes: (freq, start_s, dur_s, gain, wave, detune_hz[, end_freq]).
A 7th value slides the pitch from freq to end_freq over the note.
Envelope: 12 ms attack, exponential decay to the end of the note.
"""
import math, struct, wave, sys, os

SR = 44100
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

A3, D5, A4, E5, A5, E6 = 220.0, 587.33, 440.0, 659.25, 880.0, 1318.51
FIFTH_A3 = 329.63

def osc(kind, phase):
    if kind == 'tri':
        return 2 * abs(2 * (phase % 1) - 1) - 1
    return math.sin(2 * math.pi * phase)

def render(notes, tail=0.05):
    length = max(n[1] + n[2] for n in notes) + tail
    n = int(length * SR)
    buf = [0.0] * n
    for note in notes:
        freq, start, dur, gain, kind, detune = note[:6]
        end = note[6] if len(note) > 6 else freq
        i0 = int(start * SR)
        phase = 0.0
        for i in range(int(dur * SR)):
            t = i / SR
            env = min(1.0, t / 0.012) * math.exp(-5.5 * t / dur)
            f = freq + (end - freq) * (t / dur) + detune
            phase += f / SR
            buf[i0 + i] += gain * env * osc(kind, phase)
    peak = max(1e-6, max(abs(x) for x in buf))
    return [x / peak * 0.8 for x in buf]

def write(name, notes):
    data = render(notes)
    with wave.open(os.path.join(OUT, name + '.wav'), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(b''.join(struct.pack('<h', int(x * 32767)) for x in data))
    print(name, f'{len(data) / SR:.2f}s')

# per-app clicks share the key of A: A5, C#6, E6, F#6
APP_NOTES = {'calendar': 880.0, 'gmail': 1108.73, 'maps': 1318.51, 'drive': 1479.98}

write('1-send',      [(A5, 0.00, 0.07, 0.6, 'sine', 0), (E6, 0.05, 0.10, 0.5, 'sine', 0)])
for app, f in APP_NOTES.items():
    write(f'2-did-{app}', [(f, 0.0, 0.5, 0.6, 'sine', 0), (f / 2, 0.0, 0.5, 0.6, 'sine', 0)])
write('3-done',      [(E6, 0.00, 0.14, 0.6, 'sine', 0), (A5, 0.11, 0.22, 0.7, 'sine', 0)])
write('4-needs-you', [(A3, 0.00, 0.50, 1.0, 'sine', 0), (FIFTH_A3, 0.02, 0.48, 0.45, 'sine', 0)])
write('5-committed', [(A5, 0.00, 0.26, 0.6, 'sine', 0), (A4, 0.00, 0.26, 0.5, 'sine', 0), (E6, 0.26, 0.12, 0.6, 'sine', 0), (A5, 0.36, 0.18, 0.7, 'sine', 0)])
write('6-left-it',   [(A3, 0.00, 0.25, 0.6, 'sine', 0), (A4, 0.00, 0.25, 0.25, 'sine', 0), (164.81, 0.20, 0.42, 0.6, 'sine', 0), (FIFTH_A3, 0.20, 0.42, 0.25, 'sine', 0)])
write('7-unsure',    [(D5, 0.00, 0.18, 0.5, 'sine', 0), (D5, 0.22, 0.20, 0.5, 'sine', 6)])
write('8-incoming',  [(E5, 0.00, 0.08, 0.5, 'sine', 0), (A4, 0.07, 0.14, 0.5, 'sine', 0)])
