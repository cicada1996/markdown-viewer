# Markdown Viewer

A tiny native macOS app that opens `.md` files in a clean, read-only window —
no editor, no chrome, just rendered Markdown (GitHub-style, with automatic
dark mode).

## Features

- Double-click any `.md` / `.markdown` file in Finder and it opens here
- Live reload: if the file changes on disk (e.g. an LLM or editor rewrites it),
  the view updates in place and keeps your scroll position
- Edit mode: the pencil button (or Cmd+E) switches to a plain-text Markdown
  editor; Cmd+S saves, toggling back to preview auto-saves and re-renders
- Light/dark switch: the sun/moon button (or Cmd+Shift+D) flips the whole
  app instantly; the choice is remembered across launches
- Web links open in your browser; links to other `.md` files open in a new
  viewer window (tabs by default)
- GFM support: tables, task lists, strikethrough, fenced code blocks
- Cmd+O open, Cmd+R reload, Cmd+0/+/- zoom, pinch to zoom, Cmd+W close

## Build & install

```bash
./build.sh
```

This compiles the app, installs it to `~/Applications/Markdown Viewer.app`,
registers it with LaunchServices, and sets it as the system default for
Markdown files.

If the default ever gets reset: right-click a `.md` file in Finder →
Get Info → "Open with" → Markdown Viewer → **Change All…**

## Layout

- `Sources/main.m` — the whole app (AppKit + WKWebView, Objective-C)
- `Sources/set_default.m` — helper that sets the default `.md` handler
- `Resources/template.html` — page template and CSS (GitHub-like styling)
- `Resources/marked.min.js` — bundled Markdown parser (marked v12, MIT)
- `Info.plist` — declares the app as a Markdown viewer to macOS
- `sample.md` — test file covering common Markdown features

Built with plain `clang` — no Xcode project needed.
