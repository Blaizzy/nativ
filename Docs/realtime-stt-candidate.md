# Candidate live-input STT adoption

The Nativ Python overlay imports the mlx-vlm application, so it automatically
exposes `/v1/audio/transcriptions/realtime` when the underlying mlx-vlm package
provides that route. No second mlx-audio app, model registry, or audio worker
should be mounted in Nativ.

This is a candidate integration, not enabled by changing production pins:

- mlx-audio https://github.com/Blaizzy/mlx-audio/pull/945 is merged; released
  mlx-audio 0.5.9 provides the Nemotron live-input session contract.
- mlx-vlm https://github.com/Blaizzy/mlx-vlm/pull/2167 exposes that contract on
  its existing authenticated router/audio worker
  (candidate refreshed on upstream `6d2f226`).
- Nativ's existing `--mlx-vlm-source` and `--mlx-audio-source` build arguments
  accept local candidate checkouts. Release requirements remain unchanged until
  compatible upstream releases are available.

## Reproduce without modifying the installed app

Use a disposable Python environment with the candidate packages and Nativ's
server dependencies installed. The live route is checked by connecting to it,
not by inspecting FastAPI's internal route list. Use an existing local Nemotron model snapshot;
the probe enforces offline mode. Create non-personal synthetic fixtures, e.g.
with macOS `say` and `afconvert`, as mono 16-bit little-endian PCM WAV at 16 kHz.
Use a spoken phrase long enough to observe partial output before it ends.

```sh
python PythonDistribution/Scripts/probe_realtime_stt.py \
  --model /absolute/path/to/local/nemotron/snapshot \
  --wav /absolute/path/to/synthetic-pt.wav \
  --wav /absolute/path/to/synthetic-en.wav
```

The probe starts the actual Nativ overlay on a temporary loopback socket,
redirects analytics to a new temporary directory, disables inherited preloads
and API-key configuration only inside that process, streams PCM in paced 20 ms
chunks, asserts partial output before commit and final output afterwards, and
stops its server. It prints the synthetic transcript and timings as JSON.
It does not start the installed application or replace its bundle. Temporary
proof analytics remain under the `nativ-stt-proof-` OS temporary directory prefix
for inspection.

For a separate disposable distribution build, the existing builder accepts:

```sh
python PythonDistribution/Scripts/build_mlx_vlm_server.py \
  --mlx-vlm-source /absolute/path/to/candidate/mlx-vlm \
  --mlx-audio-source /absolute/path/to/candidate/mlx-audio \
  --output /absolute/path/to/disposable/output \
  --cache-dir /absolute/path/to/disposable/cache
```

That packaging step is distinct from the overlay/socket proof below; it has
not been certified by that proof.

## Observed proof

On 16 October 2026, Nativ's unmodified overlay at upstream
`a3888494f2d51bbff3b13730d1c5fcce1d59b849` with the mlx-vlm candidate above,
released mlx-audio 0.5.9, MLX 0.32.4 and Nemotron 3.5 0.6B snapshot
`e550040c0478027ed679b2b6b0d055502c103663` passed both synthetic fixtures:

| Fixture | Audio duration | First partial | Commit to final |
| --- | ---: | ---: | ---: |
| English | 10.074 s | 3.427 s | 0.605 s |
| Portuguese | 13.150 s | 2.052 s | 0.187 s |

Both produced partials before commit and final transcripts afterwards. The
probe exited successfully after stopping the loopback server. These are
single-run functional observations, not latency percentiles, microphone UX
proof, transcription-accuracy certification, sustained-load certification, or
proof of an updated packaged app. The mlx-vlm server and realtime STT tests
passed 672 tests with six skips.

The candidate endpoint is single-utterance, native-rate PCM16, greedy decoding,
manual commit only. It has bounded queues and duration limits and exclusively
reserves the audio worker. There is no automatic VAD, resampling, or full OpenAI
Realtime compatibility claim. See the mlx-vlm candidate's `docs/realtime-stt.md`.
