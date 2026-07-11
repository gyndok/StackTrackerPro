# Screenshot capture

`make-screenshots.sh` produces App Store-ready marketing screenshots by
driving the app's DEBUG-only demo mode (`-DemoData -DemoRoute <route>`)
through all 8 routes on a 6.9"-class simulator.

## Run it

```
tools/screenshots/make-screenshots.sh
```

Requires Xcode + a booted-capable iOS simulator runtime. The script:

1. Picks the newest iOS runtime and a "Pro Max"-named device (creates one
   named "Screenshot 6.9" if none exists).
2. Builds Debug into `tools/screenshots/.build` (gitignored) and installs it.
3. Sets a clean status bar (9:41, full battery/signal) via `simctl status_bar`.
4. Launches each route, waits 3s, and screenshots it.
5. Clears the status bar and prints a size table (App Store 6.9" = 1320x2868;
   anything else prints a WARNING).

Re-running is safe: it reuses the simulator/device and overwrites existing
PNGs.

## Output

`marketing/screenshots/01-graph.png` … `08-share.png` (committed to the
repo). Re-run this script any time the UI changes to refresh the whole set —
it always regenerates all 8 files from HEAD.
