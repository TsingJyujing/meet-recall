# meet-recall
A mac CLI for record meetings automatically

## Run

```sh
swift run meetrec --output-dir ./meetings
```

The output directory defaults to `./recordings` and is created when needed. The CLI records the macOS system audio mix to `speaker.m4a` and the microphone to `mic.m4a`; press Ctrl+C to finalize both files and stop. It does not overwrite existing recordings. Use `--sample-rate 44100` to set one rate for both files; valid values are 8000–96000 Hz and the default is 48000 Hz.

Swift code can hold a recorder and control its lifetime directly:

```swift
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

Recording requires macOS 13 or later and Screen & System Audio Recording plus Microphone permission for the terminal app running the CLI. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording and Microphone. The two files are captured separately and are not yet guaranteed to be sample-accurately synchronized.
