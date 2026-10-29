# meet-recall
A mac CLI for record meetings automatically

## Run

```sh
swift run meetrec --output-dir ./meetings --metrics-port 9090
curl http://127.0.0.1:9090/metrics
```

The output directory defaults to `./recordings` and is created when needed. The CLI records the macOS system audio mix to `speaker.m4a` and the microphone to `mic.m4a`; press Ctrl+C to finalize both files and stop. It does not overwrite existing recordings. Use `--sample-rate 44100` to set one rate for both files; valid values are 8000–96000 Hz and the default is 48000 Hz.

The Prometheus endpoint is disabled by default (`--metrics-port 0`). When enabled, it binds to `127.0.0.1` and exposes `meetrec_in_meeting`, `meetrec_recording`, `meetrec_microphone_active`, and the cumulative `meetrec_recording_starts_total` counter at `/metrics`.

Each recording session directory contains a `meta.json` with the trigger (`zoom` or `google_chrome`), ISO 8601 UTC start and end timestamps, and the matching calendar events. `calendar_events` is `null` when calendar lookup is disabled, and an empty array when enabled but no events match. Existing metadata is preserved at recording start; only `ended_at` is updated when recording stops.

Swift code can hold a recorder and control its lifetime directly:

```swift
import Logging

LoggingSystem.bootstrap(StreamLogHandler.standardError)

let recorder = MeetingRecorder(
    speakerOutputURL: URL(fileURLWithPath: "recordings/speaker.m4a"),
    microphoneOutputURL: URL(fileURLWithPath: "recordings/mic.m4a"),
    sampleRate: 48_000
)
try await recorder.start()

// The capture continues while other async work runs.
await monitorMeetings()

try await recorder.stop()
```

The CLI sends swift-log output to standard error. An application embedding the recorder should bootstrap its preferred swift-log handler once before starting a recorder.

Recording requires macOS 13 or later and Screen & System Audio Recording plus Microphone permission for the terminal app running the CLI. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording and Microphone. The two files are captured separately and are not yet guaranteed to be sample-accurately synchronized.
