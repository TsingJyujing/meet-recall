# meet-recall

macOS 命令行工具：后台监测会议状态，在会议期间分别录制系统音频和默认麦克风，并按会议和时间整理文件。

我完全没写过Swift，只是因为评估了一下觉得和操作系统绑定太强所以用Swift开发会比较顺利一些。
一边用AI写一边学，所以不敢保证质量，各位自行斟酌着用。

## 第一部分：CLI 使用方法

### 环境要求

- macOS 14.2 或更新版本。
- Swift 6.4 或更新版本。
- 首次运行时，为启动 CLI 的 Terminal 或其他宿主程序授予麦克风权限和“屏幕与系统音频录制”权限。
- 使用 Google Chrome 会议检测时，还需要允许宿主程序通过“自动化”控制 Google Chrome。

### 编译与启动

开发时可以直接运行：

```sh
swift run meetrec --help
swift run meetrec --output-dir ./recordings
```

编译 Release 可执行文件并运行：

```sh
swift build -c release
.build/release/meetrec --help
.build/release/meetrec --output-dir ./recordings
```

指定日历文件、刷新间隔和 metrics 端口的示例：

```sh
swift run meetrec \
  --output-dir ./recordings \
  --sample-rate 48000 \
  --calendar-file ./dev/calendar.json \
  --calendar-refresh-interval 600 \
  --metrics-port 9090 \
  --log-level info
```

### CLI 参数

| 参数 | 默认值 | 效果 |
| --- | --- | --- |
| `-o`, `--output-dir <path>` | `./recordings` | 录音文件根目录。相对路径以当前工作目录为基准；支持 `~`。 |
| `--sample-rate <Hz>` | `48000` | Speaker 和 Mic 共用的采样率，允许 `8000` 到 `96000` Hz。麦克风输入会转换到此采样率。 |
| `--metrics-port <port>` | `0` | `0` 不启动 HTTP 服务；`1` 到 `65535` 启动 Prometheus metrics 服务，只监听 `127.0.0.1`。 |
| `--calendar-file <path>` | 未设置 | 指定 Google Calendar JSON 文件。命令行参数优先；未提供时读取 `MEETREC_CALENDAR_FILE`。 |
| `--calendar-refresh-interval <seconds>` | `600` | 日历文件自动刷新间隔，单位为秒，必须大于 `0`。仅在启用日历查询时有实际作用。 |
| `--log-level <level>` | `info` | 日志等级：`trace`、`debug`、`info`、`notice`、`warning`、`error` 或 `critical`。日志写入标准错误。 |
| `-h`, `--help` | — | 显示命令帮助。 |

启用 metrics 后，可通过以下地址读取数据：

```sh
curl http://127.0.0.1:9090/metrics
```

程序持续运行并监测会议；按 `Ctrl+C` 会先停止当前录音、完成文件写入后退出。

## 第二部分：模块与设计

### 后台监测与会议判定

程序启动后立即检查一次会议状态，之后每 5 秒检查一次。`MeetingStatusMonitor` 先检查当前默认输入设备的活跃状态，再读取正在使用该设备的进程信息。录音和会议判定都针对默认麦克风；开始录音前会在日志中输出麦克风名称。

会议触发条件是默认麦克风有活跃输入，并满足以下应用条件之一：

- 使用麦克风的进程名称为 `zoom.us`，触发类型为 Zoom。
- 使用麦克风的进程名称包含 `Google Chrome`，且 Chrome 某个 Tab 的 URL 以 `https://meet.google.com/meet/` 开头，触发类型为 Google Chrome。Tab URL 通过主线程上的 `NSAppleScript.executeAndReturnError` 获取。

两种应用条件同时成立时，优先选择 Zoom。会议状态从 false 变为 true 时，CLI 创建并启动一个 `MeetingRecorder`；会议状态变为 false 时，停止当前录音。监测状态读取失败时会输出 Warning，并保留当前录音状态。按 `Ctrl+C` 或 metrics 服务意外结束时，CLI 也会统一停止录音并完成文件收尾。

### 日历事件查找

日历查询使用 `--calendar-file` 或 `MEETREC_CALENDAR_FILE` 指定的 JSON 文件。程序启动时加载日历数据，首次加载成功后进入后台监测。

每次查找事件前，程序检查距上次成功加载是否已达到刷新间隔。默认间隔为 10 分钟，可通过 `--calendar-refresh-interval` 修改。后续刷新失败时记录 Warning，并继续使用上次成功加载的事件；下一次事件查找时再次尝试刷新。

事件查询把查询时间向后偏移 5 分钟，再匹配包含该时间点的事件。等价的匹配窗口是 `[事件开始时间 - 5 分钟, 事件结束时间 - 5 分钟)`，包含起点、不包含终点。查询结果包含所有符合条件的事件，并按开始时间排序。匹配事件具有明确的开始和结束时刻，状态为非取消/非拒绝，类型为默认或未指定，且当前用户未拒绝。

只有恰好匹配到一个事件时，才使用该事件的标题和日历开始时间命名会话目录。匹配到零个或多个事件时，标题使用 `unknown`，目录时间使用录音启动时间。无论匹配数量多少，所有匹配事件都会写入 `meta.json`。

### 录音器与音频格式

`MeetingRecorder` 提供异步的 `start()` 和 `stop()` 生命周期接口，并协调两路独立录音：

- **Speaker**：`SystemAudioRecorder` 使用 ScreenCaptureKit 录制 macOS 系统音频混音，排除本进程自身音频，输出双声道 AAC/M4A，目标码率为 192 kbps。
- **Mic**：`MicrophoneRecorder` 使用 AVAudioEngine 录制当前默认麦克风，必要时通过 AVAudioConverter 转换到 `--sample-rate` 指定的采样率，输出 AAC/M4A，目标码率为 128 kbps；声道数跟随麦克风输入格式。

两路文件共用一个采样率设置，分别采集和编码；文件名使用相同的 `HHmmss`，便于配对。录音输出使用不同路径的 `.m4a` 文件。

`MeetingRecorder` 也可从 Swift 异步代码控制；调用方需要保留 recorder 实例直到 `stop()` 完成，并在应用中先配置 swift-log：

```swift
import Foundation
import Logging

LoggingSystem.bootstrap(StreamLogHandler.standardError)

let recorder = MeetingRecorder(
    speakerOutputURL: URL(fileURLWithPath: "recordings/speaker.m4a"),
    microphoneOutputURL: URL(fileURLWithPath: "recordings/mic.m4a"),
    sampleRate: 48_000
)
try await recorder.start()

await monitorMeetings()

try await recorder.stop()
```

### 文件布局与 `meta.json`

每次录音写入以下目录结构：

```text
<output-dir>/
  <YYYY-MM-DD>/
    <HHmm>-<title|unknown>/
      <HHmmss>-speaker.m4a
      <HHmmss>-mic.m4a
      meta.json
```

目录中的日期和时间使用本机时区。日期取录音启动日期；会话目录的 `HHmm` 在恰好匹配一个日历事件时取事件开始时间，否则取录音启动时间。两个音频文件共用录音启动时生成的 `HHmmss`，用于配对。标题中的斜线和换行会被清理，以免破坏目录结构。

`meta.json` 记录：

- `trigger`：`zoom` 或 `google_chrome`；
- `started_at`：录音启动时间；
- `ended_at`：停止录音时写入的结束时间；
- `calendar_events`：所有匹配事件。每个事件包含标题、起止时间，以及可用的位置、描述和会议/日历 URL。

时间戳使用带小数秒的 UTC ISO 8601 格式。日历文件未配置时 `calendar_events` 为 `null`；配置日历但没有匹配事件时是空数组 `[]`。若 `meta.json` 已存在，沿用已有内容；停止录音时更新 `ended_at`。

### 代码模块、日志与 metrics

| 模块 | 职责 |
| --- | --- |
| `meetrec.swift` | 使用 swift-argument-parser 解析 CLI 参数、运行 5 秒监测循环、决定开始/停止录音，并处理 Ctrl+C 和服务退出。 |
| `MeetingStatusMonitor.swift` | 检查默认麦克风的活跃进程，识别 Zoom 和 Google Meet Tab。 |
| `CalendarInfo.swift` | 解析 Google Calendar JSON、筛选事件，并按需刷新日历缓存。 |
| `MeetingRecorder.swift` | 对外提供两路录音的统一启动和停止接口。 |
| `SystemAudioRecorder.swift` | 通过 ScreenCaptureKit 捕获系统音频并写入 M4A。 |
| `MicrophoneRecorder.swift` | 捕获默认麦克风、转换采样率并写入 M4A。 |
| `RecordingMetadata.swift` | 创建会话元数据，并在停止时补写结束时间。 |
| `MeetrecMetrics.swift` | 使用 swift-metrics 收集指标，并通过 Prometheus 和 Hummingbird 暴露 `/metrics`。 |

日志统一使用 swift-log。CLI 的 `--log-level` 控制标准错误日志等级；录音开始和结束以 Info 等级记录。

启用 metrics 时提供以下指标：

- `meetrec_in_meeting`：当前会议状态，`1` 表示在会议中；
- `meetrec_recording`：当前录音状态；
- `meetrec_microphone_active`：默认麦克风是否有活跃输入；
- `meetrec_recording_starts_total`：录音启动累计次数，只在录音状态从 false 变为 true 时增加。
