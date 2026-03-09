#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="ChaturbateDVR"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_PATH="$CONTENTS_DIR/Info.plist"
ICON_NAME="AppIcon"
ICONSET_DIR="$DIST_DIR/${ICON_NAME}.iconset"
ICON_SOURCE_PATH_DEFAULT="$DIST_DIR/chaturbate-icon-source.png"
ICON_SOURCE_PATH="${ICON_SOURCE_PATH:-$ICON_SOURCE_PATH_DEFAULT}"
ICON_SOURCE_URL="${ICON_SOURCE_URL:-https://web.static.mmcdn.com/images/logo-square.png}"
ICON_STYLE="${ICON_STYLE:-native}"
ICON_WORK_PATH="$DIST_DIR/chaturbate-icon-work.png"

echo "Building release executable..."
cd "$ROOT_DIR"
swift build -c release

EXECUTABLE_PATH="$ROOT_DIR/.build/release/$APP_NAME"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "Error: expected executable not found at $EXECUTABLE_PATH"
  exit 1
fi

echo "Creating app bundle at: $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Preparing app icon..."
if [[ ! -f "$ICON_SOURCE_PATH" ]]; then
  echo "Downloading icon source from: $ICON_SOURCE_URL"
  curl -fLsS "$ICON_SOURCE_URL" -o "$ICON_SOURCE_PATH"
fi

cp "$ICON_SOURCE_PATH" "$ICON_WORK_PATH"

if [[ "$ICON_STYLE" == "native" ]]; then
  echo "Applying native-style icon treatment..."
  swift - "$ICON_WORK_PATH" <<'SWIFT'
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Missing icon path argument\n", stderr)
    exit(1)
}

let inputPath = args[1]
let outputPath = inputPath
let canvasSize = NSSize(width: 1024, height: 1024)

guard let sourceImage = NSImage(contentsOfFile: inputPath) else {
    fputs("Could not open source image at \(inputPath)\n", stderr)
    exit(1)
}

let outputImage = NSImage(size: canvasSize)
outputImage.lockFocus()

NSColor.clear.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

let iconRect = NSRect(x: 58, y: 58, width: 908, height: 908)
let cornerRadius: CGFloat = 210

// Soft shadow behind icon plate.
let shadowPath = NSBezierPath(roundedRect: iconRect.offsetBy(dx: 0, dy: -8), xRadius: cornerRadius, yRadius: cornerRadius)
NSColor.black.withAlphaComponent(0.18).setFill()
shadowPath.fill()

// Clip source into rounded square.
let clipPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
clipPath.addClip()

let srcSize = sourceImage.size
let srcAspect = srcSize.width / max(srcSize.height, 1)
let dstAspect = iconRect.width / iconRect.height

var drawRect = iconRect
if srcAspect > dstAspect {
    let width = iconRect.height * srcAspect
    drawRect.origin.x -= (width - iconRect.width) / 2
    drawRect.size.width = width
} else {
    let height = iconRect.width / max(srcAspect, 0.0001)
    drawRect.origin.y -= (height - iconRect.height) / 2
    drawRect.size.height = height
}

sourceImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

// Subtle top highlight and border for a more native app icon look.
let highlight = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor.white.withAlphaComponent(0.10).setStroke()
highlight.lineWidth = 4
highlight.stroke()

outputImage.unlockFocus()

guard
    let tiffData = outputImage.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Could not encode styled icon\n", stderr)
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Could not write styled icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
SWIFT
fi

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_WORK_PATH" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
done

sips -z 32 32 "$ICON_WORK_PATH" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
sips -z 64 64 "$ICON_WORK_PATH" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
sips -z 256 256 "$ICON_WORK_PATH" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 512 512 "$ICON_WORK_PATH" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 1024 1024 "$ICON_WORK_PATH" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/${ICON_NAME}.icns"

cp "$EXECUTABLE_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>ChaturbateDVR</string>
    <key>CFBundleDisplayName</key>
    <string>ChaturbateDVR</string>
    <key>CFBundleIdentifier</key>
    <string>com.teacat.chaturbatedvr</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>ChaturbateDVR</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS will treat this as an app bundle.
/usr/bin/codesign --force --deep --sign - "$APP_DIR"

# Touch bundle so Finder notices updated metadata/icon immediately.
touch "$APP_DIR"

echo "Done. App bundle created:"
echo "  $APP_DIR"
echo ""
echo "Open it with:"
echo "  open \"$APP_DIR\""
