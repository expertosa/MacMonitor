# Changelog

All notable changes to MacMonitor. Versions follow the `VERSION` file and `vX.Y.Z` git tags.

## [1.1.0]

### Added
- **Desktop & Notification Center widgets** (WidgetKit, macOS 13+; desktop placement on macOS 14+):
  - *This Mac* (small / medium / large): CPU ring, memory, disk, battery or GPU, network; the
    large size also lists your servers.
  - *Servers* (small / medium / large): status, CPU, memory and fullest disk of every SSH server,
    with warnings (failed services, reboot required, pending updates).
  - Clicking a widget opens the panel or the server settings (`macmonitor://` URL scheme).
- **Settings window** (⌘,): menu bar items and style (text or CPU sparkline), sampling interval
  (1 / 2 / 5 s), panel theme (warm, dark, match system), size, screen corner, visible sections,
  alert thresholds, server management, update checks.
- **Alerts** (macOS notifications): sustained high CPU, critical memory pressure, disk almost full,
  low battery; server unreachable / back online, server CPU and disk, stopped systemd services,
  reboot required.
- **More Mac stats**: memory pressure and swap, GPU utilization, battery level / charging /
  power draw / time remaining, CPU & GPU temperature and fan speed (SMC, direct edition, best
  effort), top 3 processes (direct edition, optional).
- **Servers**:
  - Import hosts from `~/.ssh/config` (follows `Include`, skips wildcard patterns).
  - Edit servers, reorder them, compact (header-only) mode, hide filesystems.
  - Watch systemd services, Docker container count, uptime, reboot-required flag, pending
    apt/dnf updates (checked every 30 min).
  - **macOS servers** over SSH (sysctl, vm_stat, netstat, top) in addition to Linux.
  - "Open SSH in Terminal" and "Copy SSH Command" per server.
- Menu items to open Activity Monitor and Disk Utility.
- Update check against GitHub Releases (direct edition, daily, can be turned off).
- `MacMonitorCore` library with unit tests (runs on Linux and macOS), GitHub Actions CI,
  release workflow producing a DMG + ZIP, Homebrew cask template, MIT license.

### Changed
- Code split into `MacMonitorCore` (parsing, sampling, alerts), `MacMonitorUI` (shared SwiftUI
  views used by the panel and the widget) and the app target. `Panel.swift` was split up.
- Xcode project moved from `AppStore/` to `Xcode/` and now has two app targets
  (`MacMonitorDirect`, `MacMonitorAppStore`) plus the widget extension.
- Version is read from the `VERSION` file by `build_app.sh` and the release scripts.

## [1.0.0]
- Menu bar CPU / RAM, desktop panel with CPU ring + history, memory, disks and network.
- Linux servers over SSH with no agent. Mac App Store edition without SSH.
