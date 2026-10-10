# Mac Profiler

A menu-bar app for your Mac. It stays running and shows live performance against the ceiling for each reading: 100% for the processor and GPU, installed memory and disk, the current Wi-Fi radio rate, and the battery’s design capacity.

Closing the dashboard leaves the app running. The menu bar keeps a short CPU, memory, and battery summary.

## Requirements

- A Mac on macOS 14 or later
- Swift 6, from the Xcode Command Line Tools (Xcode 16 or later)

No third-party packages. The app links only Apple frameworks: SwiftUI, IOKit, CoreWLAN, AppKit, and CoreGraphics.

Check the toolchain:

```bash
xcode-select -p
swift --version
```

If `swift` is missing, install the tools and open them once so the license is accepted:

```bash
xcode-select --install
sudo xcodebuild -license accept
```

## Setup

Clone the repo and build a local app:

```bash
git clone https://github.com/aditya-kaushik-arable/mac-performance-profiler.git
cd mac-performance-profiler
zsh scripts/build-app.sh
open "build/Mac Profiler.app"
```

`scripts/build-app.sh` compiles a release binary, wraps it in `build/Mac Profiler.app`, and ad-hoc signs it so macOS will launch a locally built app.

To keep it somewhere Spotlight can find after you delete the checkout:

```bash
mkdir -p "$HOME/Applications"
cp -R "build/Mac Profiler.app" "$HOME/Applications/Mac Profiler.app"
open "$HOME/Applications/Mac Profiler.app"
```

To start it at login, open System Settings → General → Login Items and add **Mac Profiler**.

The first second shows “Measuring…” for rates. Processor, disk, and network bars need one interval of counters before they move.

## Use

The dashboard opens on launch. The menu bar item shows the same sample and can reopen the window or quit.

Quit from the menu-bar panel, or with Mac Profiler → Quit. Closing the window does not quit.

A text snapshot, useful over SSH or in a terminal, samples for about a second and prints every reading:

```bash
swift build -c release
.build/release/MacProfiler --dump
```

Run that from a terminal, not while you also need a second copy. The bundle id allows one instance.

## What each bar means

| Section | Live reading | Ceiling |
| --- | --- | --- |
| Processor | Busy, user, system, nice, idle, each core, 1/5/15 min load | 100%, or one load point per core |
| Memory | Used, app, wired, compressed, cached, free, swap | Installed RAM, or the current swap file |
| Graphics | Device, renderer, and tiler utilization, GPU memory | 100%, or installed unified memory |
| Storage | Space used, read and write speed | Disk size, and the published class peak for this Mac’s SSD |
| Network | Signal, signal-to-noise, bytes in and out | −30 dBm, 60 dB, and the current Wi-Fi PHY rate or link rate |
| Battery | Charge, health, cycles, cell temperature, watts | Current full charge, design capacity, 1,000 cycles, 45°C, and a sustained power envelope for this machine |
| Display | Pixel count and refresh | The largest mode and highest refresh macOS reports |
| System | Thermal pressure and process count | Critical thermal state, and `kern.maxproc` |

The busiest processes are listed under the cards. A process percentage is its share of every core together, with the single-core figure beside it. 100% of one core on an 8-core Mac is 12.5% of the machine.

Page ins, compressions, disk operations, thread count, uptime, and power source are shown as numbers. macOS does not publish a hardware ceiling for those.

SSD speed and the power envelope are class figures for that Mac, not a benchmark the app just ran. A quiet disk sitting near 0% of a 2,200 MB/s peak is the expected reading.

## Privacy and limits

Sampling stays on the Mac. Nothing is uploaded.

macOS does not give normal apps the CPU or GPU die temperature. The heat section uses battery cell temperature and the system thermal-pressure state (Nominal, Fair, Serious, Critical).

The Wi-Fi name is shown only when macOS already allows it. Radio rate and signal strength do not need that permission. Grant Location to this app later if you want the network name filled in.

Battery watts are measured from the battery’s voltage and current. On a charger, that number is charging power, not total wall draw.

## Project layout

```
Package.swift                 Swift package
Info.plist                    App name, bundle id, and macOS minimum
Sources/MacProfiler/          Sampler, model, and SwiftUI dashboard
scripts/build-app.sh          Release build, app bundle, ad-hoc signature
```

`.build/` and `build/` are local compiler output. They are gitignored.

## Rebuild

From the repo root, after any source change:

```bash
zsh scripts/build-app.sh
open "build/Mac Profiler.app"
```

If an older copy is still running, quit it first. macOS will otherwise keep the instance that is already open.
