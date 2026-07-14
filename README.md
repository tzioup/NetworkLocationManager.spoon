# NetworkLocationManager.spoon

A Hammerspoon Spoon that automatically switches macOS Network Locations based on your WiFi network.

**The problem:** You need a static local IP on your home network (for port forwarding, self-hosted services, P2P apps) but DHCP everywhere else. macOS has Network Locations for this, but switching them manually doesn't survive daily use.

**The deeper problem:** Every CLI method for reading the WiFi SSID on macOS is broken:

| Method | Status on macOS 14+ |
|--------|-------------------|
| `/System/Library/PrivateFrameworks/.../airport -I` | Deprecated, removed |
| `networksetup -getairportnetwork en0` | Returns "not associated" even when connected |
| `wdutil info` | Requires root + entitlements |
| `system_profiler SPAirPortDataType` | Redacts SSID as `<redacted>` |
| `ipconfig getsummary en0` | Redacts BSSID |

**The solution:** Hammerspoon's `hs.wifi` module uses CoreWLAN directly, which works with a one-time Location Services grant. This Spoon wraps it into a fire-and-forget network location switcher with a gateway MAC fallback for environments where Location Services can't be granted.

## Install

Download and double-click `NetworkLocationManager.spoon.zip`, or manually drop the `NetworkLocationManager.spoon` directory into `~/.hammerspoon/Spoons/`.

## Setup

### 1. Create your macOS Network Locations

Open **System Settings → Network → ⋯ → Locations** (or run `scselect` in Terminal to see existing ones).

Create a location with a static IP — for example, `Home` with IP `192.168.1.100`, matching your router's port forwarding rule. The default `Automatic` location uses DHCP.

### 2. Configure the Spoon

Add to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("NetworkLocationManager")

spoon.NetworkLocationManager.locations = {
  ["Home"] = {
    ssids = { "MyWiFi", "MyWiFi_5G", "MyWiFi_EXT" },
    gateway_mac = "aa:bb:cc:dd:ee:ff",  -- optional fallback
  },
}
spoon.NetworkLocationManager.defaultLocation = "Automatic"
spoon.NetworkLocationManager:start()
```

To find your gateway MAC:
```bash
arp -n $(route -n get default | awk '/gateway:/{print $2}')
```

### 3. Grant Location Services

On first load, macOS will prompt you to grant Hammerspoon location access. Click **Allow**. If the prompt doesn't appear, go to **System Settings → Privacy & Security → Location Services** and toggle Hammerspoon on.

Without this, SSID detection returns nil and the Spoon falls back to gateway MAC matching (functional but adds ~4 seconds per switch for DHCP to settle).

## Configuration options

| Property | Default | Description |
|----------|---------|-------------|
| `locations` | `{}` | SSID → Network Location mapping (see example above) |
| `defaultLocation` | `"Automatic"` | Fallback location when no SSID matches |
| `configFile` | `nil` | Optional path to a JSON config file (see below) |
| `pollInterval` | `60` | Seconds between background checks. `0` to disable. |
| `settleTime` | `12` | Cooldown after a switch to prevent feedback loops |

### JSON config file (alternative to Lua config)

If you'd rather edit JSON than Lua, set `configFile` and skip the `locations` property:

```lua
hs.loadSpoon("NetworkLocationManager")
spoon.NetworkLocationManager.configFile = "~/.hammerspoon/network-locations.json"
spoon.NetworkLocationManager:start()
```

```json
{
  "locations": {
    "Home": {
      "ssids": ["MyWiFi", "MyWiFi_5G"],
      "gateway_mac": "aa:bb:cc:dd:ee:ff"
    },
    "Office": {
      "ssids": ["CorpNet"]
    }
  },
  "default": "Automatic"
}
```

The JSON file is re-read on every network change, so edits take effect without reloading Hammerspoon.

## How it works

Three detection triggers run in parallel:

1. **WiFi watcher** — fires on SSID change, power change, link change
2. **Reachability watcher** — fires when network connectivity changes
3. **Poll timer** — periodic fallback (every 60s by default)

On each trigger:

1. Try SSID matching via `hs.wifi.currentNetwork()` (needs Location Services)
2. If SSID unavailable, try gateway MAC matching via `arp`
3. If on a non-default location and nothing matches, switch to DHCP first, wait for connectivity, then re-check gateway MAC

A settling cooldown (12s default) after each switch prevents feedback loops — switching locations resets the network stack, which fires reachability changes, which would re-trigger evaluation before ARP caches repopulate.

## Debugging

Open the Hammerspoon console and run:

```lua
hs.inspect(spoon.NetworkLocationManager:currentNetwork())
```

This returns the current SSID, active Network Location, and IP address.

## Use cases

- **P2P applications** (Soulseek/Nicotine+, BitTorrent) — static IP for port forwarding at home, DHCP elsewhere
- **Self-hosted services** (Plex, Jellyfin, game servers, dev servers) — same pattern
- **VPN context switching** — different network config per location
- **DNS switching** — Pi-hole/AdGuard at home, standard DNS on the road

## Requirements

- macOS 14+ (Sonoma, Sequoia, Tahoe)
- [Hammerspoon](https://www.hammerspoon.org/) 1.0+
- At least two macOS Network Locations configured

## License

MIT
