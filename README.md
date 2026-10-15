# NGT — Next Generation Touchpad

**Turn your Mac trackpad into a graphics tablet.**

Normally a trackpad is *relative*: you drag the cursor from point A to point B.
NGT makes it *absolute*: the trackpad surface **is** the screen. Touch the top-left
corner and the cursor is instantly at the top-left of your screen. Touch the middle,
it's in the middle. No more swiping across a big display — just tap where you want to go.

Built for moments when you need to move fast: jumping between far-apart buttons,
panels, and windows during focused work.

## Features

- **Absolute positioning** — one finger maps 1:1 to the screen.
- **Gestures still work** — two or more fingers scroll and swipe as usual.
- **Clicks land where you touch** — both physical clicks and tap-to-click.
- **Multi-screen support** — pick which display the trackpad maps to from the menu,
  or cycle with **⌃⌥→ / ⌃⌥←**. A small *"Screen: …"* banner confirms the switch.
- **Remembers your screen** — falls back to the main display when a monitor is
  unplugged and returns when it's plugged back in.
- **Menu bar only** — no Dock icon. Toggle *Tablet Mode* on/off any time.
- **Featherweight** — a single ~75 KB native binary, no timers or polling,
  ~0% CPU when idle. It only does work while a finger is on the trackpad.

## Install

Requires macOS 11+ and Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/faithere1/NGT-NextGenerationTouchpad.git
cd NGT-NextGenerationTouchpad
./build.sh
open NGT.app
```

On first launch macOS asks for **Accessibility** access
(System Settings → Privacy & Security → Accessibility). Turn on **NGT**, then quit
and reopen it. The menu bar shows **NGT ●** when it's active.

Optionally drag `NGT.app` into `/Applications`.

## Usage

| Action | What happens |
|---|---|
| One finger on the trackpad | Cursor jumps to that spot on the screen |
| Two+ fingers | Normal scrolling and gestures |
| **⌃⌥→ / ⌃⌥←** | Switch to next / previous screen |
| Menu → *Tablet Mode* | Turn absolute mode on/off |
| Menu → *Screen* | Choose the target display |

## Configuration

Tweak the constants at the top of `ngt.m` and rebuild:

- `kEdgeMargin` (default `0.03`) — the outer 3% of the trackpad maps to the screen
  edges, so corners are easy to reach.
- `kClickGrace` (default `0.35`s) — how long after lifting a finger a click is still
  pinned to the touch point (for tap-to-click).

## Notes & limitations

- **Rebuilding resets permission.** Each build gets a new ad-hoc signature, so macOS
  invalidates the old Accessibility grant. `build.sh` clears the stale entry
  automatically — just re-enable NGT once after each build.
- **Uses a private Apple framework** (`MultitouchSupport`) to read raw finger
  positions. It's widely used by trackpad utilities but undocumented, so a future
  macOS update could break it.
- **Sleep / reconnect:** if tablet mode stops responding after the Mac wakes or a
  Magic Trackpad reconnects, quit and reopen NGT.
- The trackpad and screen have different aspect ratios, so drawn shapes are slightly
  stretched.

## How it works

1. `MultitouchSupport` delivers raw normalized finger positions (0–1) from the trackpad.
2. A single-finger touch is mapped to the target display's bounds and a mouse-move
   event is posted there.
3. A Quartz event tap pins the trackpad's own relative mouse events (moves, drags,
   clicks) to that absolute point, so the cursor never drifts.

All in one file: [`ngt.m`](ngt.m).

## License

[MIT](LICENSE) © faithere1
