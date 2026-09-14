# Candidate live-input STT adoption

The Nativ Python overlay imports the mlx-vlm application, so it automatically
exposes `/v1/audio/transcriptions/realtime` when the underlying mlx-vlm package
provides that route. No second mlx-audio app, model registry, or audio worker
should be mounted in Nativ.

This is a candidate integration, not enabled by changing production pins:

- mlx-audio https://github.com/Blaizzy/mlx-audio/pull/945 adds Nemotron live-input
  sessions (signed candidate `c706c4b53a149e0696dfa6f9fd3db9bb5bda6261`).
- mlx-vlm https://github.com/Blaizzy/mlx-vlm/pull/2167 exposes that contract on
  its existing authenticated router/audio worker
  (`64295d91a8535d189b0c4528371d75a28470e75a`).
- Nativ's existing `--mlx-vlm-source` and `--mlx-audio-source` build arguments
  accept local candidate checkouts. Release requirements remain unchanged until
  compatible upstream releases are available.

## Reproduce without modifying the installed app

Use a disposable Python environment with the candidate packages and Nativ's
server dependencies installed. Use an existing local Nemotron model snapshot;
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

On Apple Silicon, the unmodified Nativ overlay at
`c6b6dbe7539192cb14bc7cdf4da47fd83193804f` with the candidate packages above and
Nemotron 3.5 0.6B snapshot `e550040c0478027ed679b2b6b0d055502c103663` passed two
synthetic fixtures using this probe:

| Fixture | Audio duration | First partial | Commit to final |
| --- | ---: | ---: | ---: |
| Portuguese | 7.812 s | 2.717 s | 0.249 s |
| English | 6.753 s | 1.636 s | 0.295 s |

Both produced partials before commit. These are one-run functional observations,
not latency percentiles, microphone UX proof, sustained-load certification, or
proof of an updated packaged app. The server's separate suite passed 36 tests.

The candidate endpoint is single-utterance, native-rate PCM16, greedy decoding,
manual commit only. It has bounded queues and duration limits and exclusively
reserves the audio worker. There is no automatic VAD, resampling, or full OpenAI
Realtime compatibility claim. See the mlx-vlm candidate's `docs/realtime-stt.md`.
