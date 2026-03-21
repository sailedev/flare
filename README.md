# Flare

A native macOS screenshot tool that lives in the menu bar. Capture, beautify, annotate, and share. Free and open-source alternative to [Xnapper](https://xnapper.com).

https://github.com/user-attachments/assets/b8564489-2f6b-46d6-870a-8a3044e137fc

## Features

- Wrap screenshots in backgrounds (gradients, solid colors) with padding, shadows, and rounded corners
- Annotate with arrows, text, shapes, highlight, blur/redact, and numbered callouts
- Select and copy text from screenshots via OCR — detects sensitive content (emails, API keys) and offers one-click redaction
- Remove backgrounds using Vision subject isolation
- Full screen or selection capture (click a window, drag a region) with multi-monitor stitching
- Quick capture mode that skips the preview and goes straight to clipboard/file
- Screenshot history with thumbnails and drag-and-drop
- Export as PNG, JPG, or WebP with customizable filename templates
- Aspect ratio presets for Twitter/X, LinkedIn, 16:9, 1:1
- Global hotkeys (default: `Ctrl+Shift+1` / `Ctrl+Shift+2`)

## Install

Requires macOS 14.0 (Sonoma) or later.

### Homebrew

```bash
brew tap sailedev/flare
brew install --cask flare
```

### Download

Grab the latest `.dmg` from [Releases](https://github.com/sailedev/flare/releases).

## Build from source

Requires Xcode 16.0+.

```bash
git clone https://github.com/sailedev/flare.git
cd flare
open Flare.xcodeproj
```

Cmd+R to build and run.

## License

[MIT](LICENSE)
