# Monitor

A tiny native macOS app for Apple Silicon that shows the **CPU temperature** in the menu bar, with a dashboard for CPU and memory health.

- **Menu bar:** a monochrome template image, like Apple's own menu bar icons, that adapts to any menu bar appearance. You can show temperature, CPU and memory in any combination:
  - **Labels:** SF Symbol icons, short text ("CPU", "MEM"), or none.
  - **CPU and memory styles:** Percentage, Bar (battery-style capsule), Ring (gauge) or Graph (mini usage history).
  - **Temperature style:** `48°` or `48°C`. It turns orange at 85 °C and red at 95 °C.
- **Dropdown:** laid out like Apple's Battery and Wi‑Fi menus. The Temperature section shows the thermal state, a history graph, and SSD, battery, GPU and fan rows. The CPU section has per-core bars (Performance and Efficiency cores) and the load average. The Memory section shows App/Wired/Compressed memory, pressure and swap. It also has Open Dashboard, Activity Monitor, **Monitor Settings…** (⌘,) and Quit.
- **Dashboard window:** the same view, as a regular window.
- **Settings window:** a System Settings-style form with a live preview of the menu bar item. It also holds the temperature unit, update interval and Launch at Login.

Closing all windows removes the Dock icon, and Monitor keeps running in the menu bar.

## Build

You only need the Xcode Command Line Tools (`xcode-select --install`):

```bash
./build.sh            # builds build/Monitor.app
./build.sh --install  # also copies it to /Applications and launches it
```

Install the app to `/Applications` before turning on **Launch at Login**.

## Why it's light

- Pure AppKit (including the Settings window) with no SwiftUI or third-party dependencies. The app bundle is about 400 KB.
- One timer with tolerance, so macOS can coalesce wakeups. Sensor reads run on a background utility queue.
- The dashboard is drawn in a single `draw(_:)` pass, with no subviews or animations. It is redrawn only while it is actually on screen.
- Fans, swap, memory pressure and load average are read only while the dashboard is visible.
- The temperature sensor list is resolved once at launch, and duplicate HID services are skipped.

Measured on an M4 Pro with a 2 s update interval: about 17 MB of memory and about 0.2% of one core when only in the menu bar, and about 26 MB and 0.45% CPU with the dashboard open.

## How temperatures are read

- **Temperatures:** IOKit HID event system sensors (`PMU tdie*` on M2 and later, `pACC/eACC/GPU MTR` on M1, plus NAND and battery). These are the same sensors `powermetrics` uses. No root access is needed.
- **Fan speed:** the AppleSMC keys `FNum`, `F#Ac` and `F#Mx`.

The "CPU temperature" is the average of the SoC die sensors. "Hottest sensor" is the maximum of those sensors.
