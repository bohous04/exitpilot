# Exitpilot

A tiny macOS menu bar app that turns a [Tailscale](https://tailscale.com) exit node on automatically when you're on a restrictive network, and off again when you leave.

Office, hotel and coworking Wi-Fi often sits behind a strict (symmetric) NAT or blocks UDP. Peer-to-peer apps like **Parsec** then fail with errors such as `6023` / `6024` ("unable to negotiate a successful connection"). Routing your traffic through an exit node with a normal public IP (a cheap VPS, a home server) fixes that, but toggling it by hand is easy to forget.

Exitpilot watches for network changes, runs `tailscale netcheck`, and switches for you.

## Features

- Menu bar icon shows the state at a glance: 🌐 off · 🌐🛡 exit node on · ⚠︎ Tailscale not connected
- Automatic switching: on when the NAT is strict (`MappingVariesByDestIP`) or UDP is blocked, off on open networks
- Panel with a colour-coded status card: routing via an exit node, direct connection, restrictive network, or Tailscale off
- Connect / disconnect Tailscale itself from the panel
- Manual on/off; a manual choice (in Exitpilot or in Tailscale's own menu) is respected until you join a different network, or until you press **Resume**
- Pick which exit node to use from your tailnet
- Optional LAN access while the exit node is on (printers, local devices)
- Notifications when it switches, launch at login
- No background daemons, no network calls of its own; it only drives the Tailscale CLI

## Requirements

- macOS 13 or later
- [Tailscale for macOS](https://tailscale.com/download/mac) installed and signed in
- At least one device in your tailnet [advertised and approved as an exit node](https://tailscale.com/kb/1103/exit-nodes)

## Install

1. Download `Exitpilot.zip` from the [latest release](../../releases/latest) and move `Exitpilot.app` to `/Applications`.
2. The app is ad-hoc signed, not notarized. On first launch, right-click it → **Open**, or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Exitpilot.app
   ```
3. Click the menu bar icon, choose your exit node, and turn on **Launch at login**.

## Build from source

```sh
swift scripts/make-icon.swift   # optional, regenerates Resources/AppIcon.icns
./scripts/build.sh              # produces build/Exitpilot.app and build/Exitpilot.zip
```

## How it decides

| `tailscale netcheck` says | Network | Exitpilot |
| --- | --- | --- |
| `UDP: false` | UDP blocked | exit node **on** |
| `MappingVariesByDestIP: true` | strict / symmetric NAT | exit node **on** |
| otherwise | open NAT | exit node **off** (only if it was the one Exitpilot uses) |

Checks run on every network change and every 5 minutes. `netcheck` measures the physical network, so the result is the same whether the exit node is on or off.

## License

MIT
