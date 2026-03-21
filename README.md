# Flare

A native macOS screenshot tool that lives in the menu bar. Capture, beautify, annotate, and share. Free and open-source alternative to [Xnapper](https://xnapper.com).

https://github.com/user-attachments/assets/b8564489-2f6b-46d6-870a-8a3044e137fc

<table>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/264b08fb-4d51-4e93-a91b-00e007148d40" alt="Window capture"></td>
    <td><img src="https://github.com/user-attachments/assets/78f1674d-cb51-47d6-871b-5dc2b0eda74d" alt="Region capture"></td>
  </tr>
  <tr>
    <td><b>Window capture</b> - click any window to capture it</td>
    <td><b>Region capture</b> - drag to select any area</td>
  </tr>
  <tr>
    <td colspan="2">Both modes share a single keybind (<code>Ctrl+Shift+1</code>). Full screen capture is available on a separate keybind (<code>Ctrl+Shift+2</code>).</td>
  </tr>
</table>

<table>
  <tr>
    <td><img src="https://github.com/user-attachments/assets/0e4ba482-1de7-4aa8-a96f-861ec7dcc2fd" alt="Flare editor"></td>
    <td><img src="https://github.com/user-attachments/assets/aec4fe74-7405-4cc0-b9bd-d6abbc6051a5" alt="History manager"></td>
  </tr>
  <tr>
    <td><b>Preview editor</b> - change background, padding, inset, shadow, or remove the background entirely</td>
    <td><b>History</b> - scroll through and find past screenshots</td>
  </tr>
</table>

## Features

- Wrap screenshots in backgrounds (gradients, solid colors) with padding, shadows, and rounded corners
- Annotate with arrows, text, shapes, highlight, blur/redact, and numbered callouts
- Select and copy text from screenshots via OCR - detects sensitive content (emails, API keys) and offers one-click redaction
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
