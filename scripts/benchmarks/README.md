# Voice wake-word comparison

These probes exercise the existing implementations with synthetic WAV files. They do not
record microphone audio, paste transcripts, change the server configuration, or download
models. Tests assume an already-running Nativ server at `127.0.0.1:8080`, the installed
`CohereLabs/cohere-transcribe-03-2026` model, and installed Apple English speech assets.

Pause **Audio → Shortcuts → Hey Nativ** before running, and restore its previous state afterward.
Avoid concurrent model inference. The HTTP probe submits the same fields as `NativAudioClient`
and uses the endpoint's normal defaults, including its token limit.

From the repository root:

```sh
python3 scripts/benchmarks/voice_fixtures.py
swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
  scripts/benchmarks/voice_apple_probe.swift \
  Sources/Nativ/Features/VoiceCapture/VoiceWakeWordDetection.swift \
  Sources/Nativ/Features/VoiceCapture/VoiceWakeWordMonitor.swift \
  Sources/Nativ/Features/VoiceCapture/AudioInputLevelMonitor.swift \
  Sources/Nativ/Features/VoiceCapture/AudioInputDevicePreferences.swift \
  Sources/Nativ/Features/VoiceCapture/VoiceAudioRecorder.swift \
  Sources/Nativ/Features/VoiceCapture/RealtimeAudioMeter.swift \
  Sources/Nativ/Utilities/NativSystemPermissionController.swift \
  -o build/voice-apple-probe
swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
  scripts/benchmarks/voice_power_probe.swift \
  Sources/Nativ/Features/SystemMonitor/SystemSensorSampler.swift \
  -o build/voice-power-probe
python3 scripts/benchmarks/voice_wake_benchmark.py --mode pilot
python3 scripts/benchmarks/voice_wake_benchmark.py --mode runs
python3 scripts/benchmarks/voice_wake_benchmark.py --mode power
python3 scripts/benchmarks/summarize_voice_wake.py
```

Run modes sequentially. JSONL results append under
`test-artifacts/voice-wake-benchmark-2026-09-15`; archive earlier files before a fresh run.
The power mode replaces its sensor log.

- **pilot:** 3 trials per voice, dictation, and silence, alternating backends. Both models are
  warm. Apple preparation time is reported separately. HTTP latency includes serialization,
  transport, and server processing; Apple timing starts after preparation.
- **runs:** two 30-second trials of silence and mixed audio per engine, alternating order.
  Apple receives 100 ms PCM chunks in real time through the production audio converter.
  Cohere receives overlapping 4-second WAVs every second, one request at a time. A final
  exploratory gate skips windows with RMS below 0.003; this is not a validated speech VAD.
- **power:** silence replay for 45 seconds per phase, Apple / Cohere / Cohere / Apple, with
  15-second no-replay baselines before, between, and after. Nativ's existing sensor sampler
  runs continuously and timestamps readings for alignment with phase logs.
- **soak:** `python3 scripts/benchmarks/voice_wake_benchmark.py --mode soak` repeats the
  30-second mixed fixture for 15 minutes in one continuous Apple recognition session,
  with no scheduled renewal. The large generated WAV stays under `build/`; events and
  memory samples are appended to `soak.jsonl`. This checks behavior beyond the five-minute
  renewal interval without microphone capture or audio playback. It does not establish
  all-day stability or device-change recovery. Keep the Mac awake for a continuous-run
  comparison; a sleep interruption or a wall/monotonic clock gap invalidates that comparison.

## Interpretation

`proc_pid_rusage` CPU times are converted from Mach ticks using `mach_timebase_info`.
CPU percentages use **100% = one core**. Primary steady-state CPU and memory metrics exclude
the Python benchmark driver. Its counters remain in the raw samples and per-process data.
Apple includes the Swift input/conversion helper and accessible user speech-service processes;
Cohere includes the existing Python server. Pilot CPU metrics include driver overhead and
should be used only for latency comparisons. The Apple baseline's first sample in the recorded
initial run was empty; subsequent samples show the resting services and zero CPU work.

`ri_energy_nj` measures CPU energy, excluding GPU and Neural Engine work. This is not battery
energy. The optional hardware probe uses private, read-only IOReport and battery-controller
telemetry already present in Nativ. Missing rails are null, not zero. Package power is the
app's estimated sum of available rails; whole-system input power has a slow refresh cadence.
Neither source alone establishes battery runtime. Background desktop work also affects these
system-wide readings.

`summarize_voice_wake.py` writes `summary.json` alongside the generated recordings and
JSONL logs under `test-artifacts/voice-wake-benchmark-2026-09-15`.

The server also keeps an unrelated language model loaded. Its absolute memory footprint must
not be attributed entirely to speech recognition. The benchmark reports initial and peak
footprint so incremental memory can be inspected. Synthetic speech/silence cannot establish
real-room false-activation rates, accented-speech reliability, or microphone hardware cost.
