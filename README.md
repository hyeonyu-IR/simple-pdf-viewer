# Simple PDF Viewer (macOS)

Lightweight macOS PDF viewer built with SwiftUI + PDFKit.

This app is designed for people who mainly want to view PDF files and quickly add simple document marks such as a signature or date for office-style paperwork. It is intentionally lightweight and focused, without trying to include too many extra editing functions.

## Features
- Open a local PDF file
- View pages with native PDF rendering
- Previous / Next page navigation
- Live page indicator
- Text search (next/previous with wrap)
- Thumbnail sidebar toggle
- Session restore: last PDF, last page, sidebar/search state, and window frame
- Keyboard shortcuts: `Cmd+F`, `Cmd+G`, `Shift+Cmd+G`
- Zoom controls (`Cmd+=`, `Cmd+-`, `Cmd+0`, fit width/page)
- Draggable thumbnail pane width with persistence
- Distraction-free focus mode (`Shift+Cmd+F`)
- Zoom state persistence across relaunch
- Recent files (last 10): `File > Open Recent`
- Lightweight text stamps: `Stamp Name`, `Stamp Date`, dashed placement preview, then click page to place
- Move a placed stamp by dragging; delete selected stamp with `Delete` or `Delete Stamp` button
- Save edited PDFs (`Cmd+S`) and save-as (`Shift+Cmd+S`)
- Unsaved-change prompt when opening another PDF or closing window

## Keyboard Shortcuts
- `Cmd+O`: Open PDF
- `Cmd+F`: Focus search field
- `Cmd+G`: Find next
- `Shift+Cmd+G`: Find previous
- `Cmd+=`: Zoom in
- `Cmd+-`: Zoom out
- `Cmd+0`: Actual size
- `Shift+Cmd+F`: Toggle focus mode
- `Cmd+S`: Save edited PDF
- `Shift+Cmd+S`: Save as new PDF
- `Option+Cmd+N`: Stamp Name mode
- `Option+Cmd+D`: Stamp Date mode

## App Metadata
- `Hyeon's PDF Viewer > About Hyeon's PDF Viewer` shows app name, version, build, and credits.
- Version metadata comes from `VERSION` (currently `1.0.0`) during packaging.

## Run in Xcode
1. Open Xcode.
2. Choose `File > Open...` and select this folder (`simple-pdf-viewer`).
3. Select the `simple-pdf-viewer` scheme.
4. Press `Run`.

## Build Double-Click App Bundle
```bash
cd /Users/hyeonyu/Documents/miniconda_medimg_env/simple-pdf-viewer
./scripts/package_app.sh
```

Optional packaging overrides:
```bash
./scripts/package_app.sh --version 1.0.1 --build 101 --icon assets/AppIcon.icns
```

This creates:
- `dist/Hyeon's PDF Viewer.app`

You can launch it without Xcode:
```bash
open "dist/Hyeon's PDF Viewer.app"
```

## One-Command Install (Default PDF App)
```bash
cd /Users/hyeonyu/Documents/miniconda_medimg_env/simple-pdf-viewer
./scripts/install.sh --clean-pdf-overrides
```

What this does:
- Builds and packages the latest app
- Installs to `/Applications/Hyeon's PDF Viewer.app`
- Registers app with LaunchServices
- Sets default PDF handler to `Hyeon's PDF Viewer`
- Optionally removes per-file PDF OpenWith override in `~/Downloads` and `~/Documents`

Useful options:
- `--user`: install into `~/Applications` (no sudo path)
- `--dry-run`: print actions only

## Set a Custom Dock Icon
1. Prepare a square image (1024x1024 PNG recommended).
2. Convert it to app icon format:
```bash
cd /Users/hyeonyu/Documents/miniconda_medimg_env/simple-pdf-viewer
./scripts/make_icon_icns.sh /path/to/your-icon.png assets/AppIcon.icns
```
3. Rebuild the app bundle:
```bash
./scripts/package_app.sh
```

`package_app.sh` automatically embeds `assets/AppIcon.icns` if present.
You can also provide an icon path explicitly with `--icon` or `APP_ICON_PATH`.

## Notes
- This project is a Swift Package executable app targeting macOS 13+.
- If command-line `swift build` fails due local toolchain mismatch, run from Xcode with the active macOS SDK/toolchain.
- You can use the same repo and `./scripts/install.sh --clean-pdf-overrides` on another Mac (for example your Mac mini).
