# meet-recall
A mac CLI for record meetings automatically

## Run

```sh
swift run meetrec --output-dir ./meetings
```

The output directory defaults to `./recordings` and is created when needed. The CLI records the macOS system audio mix to `speaker.m4a` and the microphone to `mic.m4a`; press Ctrl+C to finalize both files and stop. It does not overwrite existing recordings.

Recording requires macOS 13 or later and Screen & System Audio Recording plus Microphone permission for the terminal app running the CLI. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording and Microphone. The two files are captured separately and are not yet guaranteed to be sample-accurately synchronized.
