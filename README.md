# Chaturbate DVR (Swift/SwiftUI)

A native macOS application for recording Chaturbate streams, built with Swift and SwiftUI.

> [!NOTE]
> This fork focuses on the SwiftUI rewrite of Chaturbate DVR. Favicon from [Twemoji](https://github.com/twitter/twemoji).

![Image](https://github.com/user-attachments/assets/d71f0aaa-e821-4371-9f48-658a137b42b6)

![Image](https://github.com/user-attachments/assets/43ab0a07-0ece-40ba-9a0f-045ca0316638)

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

## Legacy Project Note

This fork replaces the original Go implementation with a Swift/SwiftUI macOS app.
If you need the original multi-platform Go version, see [teacat/chaturbate-dvr](https://github.com/teacat/chaturbate-dvr).

## Troubleshooting

### Channel Shows as Offline

- Verify the channel username is correct
- Check your internet connection
- The channel may actually be offline

### Cloudflare Blocked

If you encounter Cloudflare protection:

1. Open Chaturbate in Safari/Chrome.
2. Complete the Cloudflare check.
3. Copy cookies from browser DevTools.
4. Add cookies to app configuration.

### Recording Issues

- Ensure you have sufficient disk space
- Check file permissions in the output directory
- Verify the filename pattern is valid

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
