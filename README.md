# Monitor

A tiny native macOS app for Apple Silicon that shows the **CPU temperature** in the menu bar, with a dashboard for CPU, GPU and memory health.

- **Menu bar:** a monochrome template image, like Apple's own menu bar icons, that adapts to any menu bar appearance. You can show temperature, CPU, GPU and memory in any combination:
  - **Labels:** SF Symbol icons, short text ("CPU", "GPU", "MEM"), or none.
  - **CPU, GPU and memory styles:** Percentage, Bar (battery-style capsule), Ring (gauge) or Graph (mini usage history).
  - **Temperature style:** `48°` or `48°C`.
- **Dropdown:** laid out like Apple's Battery and Wi‑Fi menus. The Temperature section shows the thermal state, a history graph, and SSD, battery and fan rows. The CPU section has per-core bars (Performance and Efficiency cores) and the load average. The GPU section has a 3-minute utilization graph, core count, GPU memory in use and GPU temperature. The Memory section shows App/Wired/Compressed memory, pressure and swap. It also has Open Dashboard, Activity Monitor, **Monitor Settings…** (⌘,) and Quit.
- **Alerts:** each metric turns orange near its limit and red when critical, in the menu bar and the dropdown. A metric you don't show in the menu bar gets a small coloured ⚠ instead. Optional notifications fire once when a metric gets worse, at most every 10 minutes per metric.
  - **Temperature:** warning at 70–90 °C (default 85 °C). Critical at 95 °C, or when macOS starts slowing the chip down to cool it.
  - **CPU:** warning at 70–95% (default 90%), averaged over 30 seconds so short bursts don't count. Critical when the CPU stays above 98%.
  - **Memory:** based on macOS memory pressure rather than % used, since macOS compresses memory and a high "used" figure is often fine. Warning at elevated pressure (or only at critical), red at critical pressure.
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
- **GPU temperature:** the AppleSMC `Tg0x`/`Tg1x` keys (average and hottest), discovered at launch. On an M4 Pro these climb from about 42 to 75 °C under a GPU-only load while the CPU sensors barely move. M1 falls back to its labelled `GPU MTR` HID sensors.
- **GPU utilization and memory:** the GPU driver's `PerformanceStatistics` in the IORegistry, the same numbers Activity Monitor's GPU History uses.
- **Fan speed:** the AppleSMC keys `FNum`, `F#Ac` and `F#Mx`.

The "CPU temperature" is the average of the SoC die sensors. "Hottest sensor" is the maximum of those sensors.
