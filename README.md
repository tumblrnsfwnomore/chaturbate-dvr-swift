# Chaturbate DVR (Swift/SwiftUI)

A native macOS application for recording Chaturbate streams, built with Swift and SwiftUI.

> [!NOTE]
> Forked from the original, now deprecated, [Go version by teacat](https://github.com/teacat/chaturbate-dvr).

## Features

- Record multiple Chaturbate streams simultaneously
- Real-time channel status and statistics
- Pause, resume, and stop recording controls
- Customizable filename patterns
- Automatic file splitting by duration or size
- Native macOS SwiftUI interface
- Persistent channel configuration

## Requirements

- macOS 13.0 or later
- Xcode 14.0 or later
- Swift 5.9 or later

## Building

## Using the shell script

The included shell script builds a complete app bundle in the dist folder.

```bash
./scripts/package-app.sh
```

### Using Xcode

1. Open `Package.swift` in Xcode.
2. Select your target device/simulator.
3. Press `Cmd+R` to build and run.

### Using Swift Package Manager

```bash
swift build
swift run
```

## Usage

### Adding a Channel

1. Click the `+` button in the toolbar.
2. Enter the channel username.
3. Configure quality settings (resolution, framerate).
4. Set limits (max duration, max file size) if needed.
5. Click `Add`.

### Managing Channels

- `Pause`: Temporarily stop recording (keeps the channel in the list)
- `Resume`: Continue recording from where you left off
- `Stop`: Remove channel from the recording list

## Configuration

Channel configurations are automatically saved to:

```text
~/Library/Application Support/ChaturbateDVR/channels.json
```

## Architecture

### Key Components

- `HTTPClient`: Handles HTTP requests with retry logic
- `ChaturbateClient`: Fetches stream information from Chaturbate
- `Playlist`: Parses HLS playlist files
- `Channel`: Manages individual channel recording
- `ChannelManager`: Coordinates multiple channels
- `ContentView`: Main SwiftUI interface

### Concurrency

The app uses modern Swift concurrency features:

- `async/await` for asynchronous operations
- `actor` for thread-safe state management
- `Task` for concurrent channel monitoring

## Troubleshooting

### Channel Shows as Offline

- Verify the channel username is correct
- Check your internet connection
- The channel may actually be offline

### Recording Issues

- Ensure you have sufficient disk space
- Check file permissions in the output directory
- Verify the filename pattern is valid
- Fragmented MP4 streams now record split audio renditions and mux audio+video on finalize when an audio group is advertised in the HLS master playlist

### Audit MP4 Timeline And Audio Health

To scan a recordings directory for likely timestamp-corrupted files (retime candidates)
and files missing an audio stream:

```bash
./scripts/audit-retime-candidates.sh --input "/path/to/recordings"
```

Useful options:

```bash
./scripts/audit-retime-candidates.sh \
  --input "/path/to/recordings" \
  --output-dir /tmp \
  --large-gap-sec 5 \
  --huge-gap-sec 30
```

The script writes a TSV report plus list files for:

- `retime_required`
- `retime_review`
- `likely_ok`
- `no_audio`

### Batch Repair Timeline-Corrupted Files

After running the retime audit, batch-repair all required candidates:

```bash
./scripts/batch-retime-repair.sh \
  --report audits/retime-audit-YYYYMMDD-HHMMSS.tsv \
  --class retime_required
```

Run a preview first:

```bash
./scripts/batch-retime-repair.sh \
  --report audits/retime-audit-YYYYMMDD-HHMMSS.tsv \
  --class retime_required \
  --dry-run
```

Review a small batch in a separate folder:

```bash
./scripts/batch-retime-repair.sh \
  --report audits/retime-audit-YYYYMMDD-HHMMSS.tsv \
  --class retime_required \
  --output-dir /tmp/retime-review \
  --limit 5
```

By default, repaired files are written as sibling files with `_retimed.mp4` suffix.
Use `--replace-source` only when you want verified outputs to replace originals.

### Batch Convert Recordings to Smaller MP4 Files

For large backlogs (hundreds or thousands of files), use the included batch conversion script:

```bash
chmod +x ./scripts/batch-handbrake-convert.sh
./scripts/batch-handbrake-convert.sh --input ~/Recordings --dry-run
```

Then run a real conversion with parallel workers:

```bash
./scripts/batch-handbrake-convert.sh --input ~/Recordings
```

The script defaults are intentionally conservative for long unattended runs:

- `workers=1`
- lower CPU priority (`nice=12`)
- short pause between launches (`sleep-between=2`)

If your machine still feels busy, reduce impact even more:

```bash
./scripts/batch-handbrake-convert.sh --input ~/Recordings --workers 1 --nice 15 --sleep-between 4
```

If your machine can handle more, increase workers gradually:

```bash
./scripts/batch-handbrake-convert.sh --input ~/Recordings --workers 2
```

If results look good and you want to reclaim space, remove originals after each verified conversion:

```bash
./scripts/batch-handbrake-convert.sh --input ~/Recordings --delete-source
```

To replace source files directly after verification (in-place workflow):

```bash
./scripts/batch-handbrake-convert.sh --input ~/Recordings --replace-source
```

Requirements:

- `HandBrakeCLI` (required)
- `ffprobe` (optional, used for duration-based verification)

## Development

### Project Structure

```text
Sources/
 ChaturbateDVR/
  Models/        # Data models
  Networking/    # HTTP client
  M3U8/          # Playlist parser
  Chaturbate/    # Chaturbate API client
  Channel/       # Channel recording logic
  Manager/       # Channel management
  Views/         # SwiftUI views
```

### Adding Features

1. Create new Swift files in the appropriate directories.
2. Follow Swift naming conventions.
3. Use `actor` for shared mutable state.
4. Use `async/await` for asynchronous operations.

## License

Same as the original Go version.
