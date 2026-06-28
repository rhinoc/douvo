# Audio Input Processing

This document describes the audio conditioning currently applied before Douvo sends microphone samples to ASR.

## Current Pipeline

`AudioCaptureManager` captures microphone audio with `AVAudioEngine`, converts it to 16 kHz mono float PCM with `AVAudioConverter`, conditions the samples, converts them to signed 16-bit PCM, then emits fixed-size packets.

For the Web ASR path, packets are 2048 samples at 16 kHz, about 128 ms per packet. On stop, Douvo flushes any partial packet and sends two silence packets so the server can finalize.

The microphone tap uses a smaller 512-frame input buffer so overlay levels can update more promptly than ASR packets are emitted.

For the Android ASR path, Douvo encodes the conditioned 16 kHz mono samples to Opus for the WebSocket request. Debug recordings are still written from the pre-Opus PCM samples, so saved files under `Recordings/` remain valid WAV files.

## Conditioning

Before float samples are converted to `Int16`, `AudioInputConditioner` applies three small safeguards:

- Replace non-finite samples (`NaN`, `+Inf`, `-Inf`) with `0`.
- Apply a one-pole high-pass filter:

  ```text
  y[n] = x[n] - x[n-1] + 0.995 * y[n-1]
  ```

  This reduces DC offset and very low-frequency rumble without using a speech/noise threshold.
- Clamp output samples to `[-1, 1]` before scaling to `Int16`.

The audio level shown in the overlay is calculated from conditioned samples. Douvo computes RMS for each converted buffer, converts it to dBFS, then maps the `-60 dB...-18 dB` range to a `0...1` visual level so quiet speech has more visible movement.

## Converter Tail Drain

When recording stops, Douvo now drains `AVAudioConverter` with an end-of-stream input before releasing it. This lets the converter emit buffered tail frames from resampling instead of dropping them.

This is intended to reduce cases where the last word or syllable is clipped before the final packet flush.

## What This Is Not

This is not VAD and it does not remove quiet speech.

Douvo currently does not:

- classify frames as speech or noise
- drop low-RMS frames
- trim silence with a speech threshold
- apply pre-roll, onset smoothing, or hangover
- keep the microphone open continuously for VAD observation

Whispers should still pass through the pipeline. The high-pass filter can reduce DC and sub-bass energy, but it does not gate audio by volume.

## Logging

Relevant logs:

- `Audio capture summary ... levelRange=...`
  - Existing periodic level summary, now based on dB-mapped visual levels calculated from conditioned samples.
- `Audio debug recording saved path=... bytes=...`
  - Saved local 16 kHz mono PCM WAV for the current recording.
- `Audio converter drained frames=...`
  - Emitted only when the converter produced tail frames during stop.
- `Audio tail flushed remainderBytes=... silencePackets=2`
  - Existing packet flush and final silence log.

There is no log for "dropped speech" because this pipeline does not drop speech frames.

## Relation To Handy VAD

Handy uses Silero VAD plus smoothing with pre-roll, onset, and hangover. That design is useful as a reference, but Douvo does not currently implement it.

If Douvo adds VAD later, the safer first step is observation mode:

- compute speech/noise metrics
- write ratios and timing to traces
- keep sending all audio unchanged
- compare ASR raw results before enabling any gate or trim

For Doubao's real-time WebSocket ASR, full frame deletion may affect server-side timing and finalization. If gating is added, prefer conservative start/end trimming before removing silence inside an utterance.

## Verification

Run the focused tests:

```bash
swift test --filter AudioInputConditionerTests
```

Run all tests:

```bash
swift test
```
