# meet-recall
A mac CLI for record meetings automatically

## Run

```sh
swift run meetrec --output-dir ./meetings
```

The output directory defaults to `./recordings` and is created when needed. The CLI records the current macOS system audio mix to `speaker.m4a`; press Ctrl+C to finalize the file and stop. It does not overwrite an existing `speaker.m4a`.

System audio capture requires macOS 13 or later and Screen & System Audio Recording permission for the terminal app running the CLI. Grant access in System Settings → Privacy & Security → Screen & System Audio Recording.
