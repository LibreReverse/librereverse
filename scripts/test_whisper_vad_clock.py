#!/usr/bin/env python3
"""Opt-in real Whisper regression; reads synthetic speech and never plays audio.
Usage: python3 scripts/test_whisper_vad_clock.py RUNTIME SPEECH_WAV
The fixture must contain the phrase 'This is' once, as our local meeting does.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import wave

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    parser.add_argument("fixture", type=Path)
    args = parser.parse_args(argv)
    runtime, fixture = args.runtime, args.fixture
    with wave.open(str(fixture)) as source:
        params = source.getparams()
        assert (params.nchannels, params.sampwidth, params.framerate) == (1, 2, 16000)
        speech = source.readframes(params.nframes)
    expected = [60, 105 + params.nframes / params.framerate]
    with tempfile.TemporaryDirectory(prefix="librereverse-word-clock-") as directory:
        root = Path(directory)
        audio = root / "passages.wav"
        output = root / "result"
        with wave.open(str(audio), "wb") as target:
            target.setparams(params)
            target.writeframes(bytes(60 * 32000) + speech + bytes(45 * 32000) + speech)
        subprocess.run([
            str(runtime / "bin/whisper-cli"), "-m", str(runtime / "Models/ggml-large-v3-turbo.bin"),
            "-f", str(audio), "-l", "en", "--vad", "--vad-model",
            str(runtime / "Models/ggml-silero-v6.2.0.bin"), "-ojf", "-of", str(output)
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        data = json.loads(output.with_suffix(".json").read_text())
        tokens = [token for segment in data["transcription"] for token in segment["tokens"]
                  if not token["text"].startswith("[_")]
        starts = [token["offsets"]["from"] / 1000 for token, following in zip(tokens, tokens[1:])
                  if token["text"].strip().lower() == "this" and following["text"].strip().lower() == "is"]
        assert len(starts) == 2 and all(abs(a - b) < 1 for a, b in zip(starts, expected)), (starts, expected)
        print(f"PASS: speech begins at {starts}; original-clock targets are {expected}")


if __name__ == "__main__":
    main()
