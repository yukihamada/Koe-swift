#!/usr/bin/env python3
"""
Koe openWakeWord detector
stdin: float32 PCM stream (16kHz, mono)
stdout: READY / DETECTED:model:score / ERROR:message
"""
import sys
import json
import struct
import numpy as np

def main():
    # First line: JSON config from Swift
    try:
        config = json.loads(sys.stdin.readline().strip())
    except Exception:
        config = {}

    model_names         = config.get("models", ["hey_jarvis"])
    threshold           = float(config.get("threshold", 0.5))
    custom_model_paths  = config.get("custom_model_paths", [])

    try:
        from openwakeword.model import Model
    except ImportError:
        sys.stdout.write("ERROR:openwakeword not installed. Run: pip install openwakeword\n")
        sys.stdout.flush()
        return

    # Load models
    try:
        models_to_load = custom_model_paths + model_names
        oww = Model(wakeword_models=models_to_load, inference_framework="onnx")
    except Exception as e:
        sys.stdout.write(f"ERROR:{e}\n")
        sys.stdout.flush()
        return

    sys.stdout.write("READY\n")
    sys.stdout.flush()

    CHUNK_SAMPLES = 1280          # 80ms @ 16kHz (openWakeWord's native window)
    CHUNK_BYTES   = CHUNK_SAMPLES * 4  # float32 = 4 bytes each
    buf = b""
    detected_cooldown = 0         # frames to skip after detection

    while True:
        data = sys.stdin.buffer.read(CHUNK_BYTES)
        if not data:
            break
        buf += data

        while len(buf) >= CHUNK_BYTES:
            chunk = buf[:CHUNK_BYTES]
            buf   = buf[CHUNK_BYTES:]

            if detected_cooldown > 0:
                detected_cooldown -= 1
                continue

            # float32 → int16 (openWakeWord expects int16)
            audio_f32 = np.frombuffer(chunk, dtype=np.float32)
            audio_i16 = (audio_f32 * 32767.0).clip(-32768, 32767).astype(np.int16)

            try:
                prediction = oww.predict(audio_i16)
            except Exception:
                continue

            for key, score in prediction.items():
                if float(score) >= threshold:
                    sys.stdout.write(f"DETECTED:{key}:{score:.4f}\n")
                    sys.stdout.flush()
                    detected_cooldown = 25  # ~2s cooldown

if __name__ == "__main__":
    main()
