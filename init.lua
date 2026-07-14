--- === NetworkLocationManager ===
---
--- Automatically switch macOS Network Locations based on WiFi SSID.
---
--- macOS 14+ broke every CLI method for reading WiFi SSIDs (`airport`,
--- `networksetup -getairportnetwork`, `wdutil info`, `system_profiler`).
--- This Spoon uses Hammerspoon's CoreWLAN bindings — the only reliable
--- path left — with a gateway MAC fallback for environments where
--- Location Services can't be granted.
---
--- Requires: Hammerspoon Location Services permission for SSID detection
--- (System Settings → Privacy & Security → Location Services → Hammerspoon).
--- Works without it via gateway MAC matching, but SSID mode is instant.
---
--- Download: [https://github.com/tzioup/NetworkLocationManager.spoon](https://github.com/tzioup/NetworkLocationManager.spoon)

local obj = {}
obj.__index = obj

obj.name = "NetworkLocationManager"
obj.version = "1.0.0"
obj.author = "tzioup (https://github.com/tzioup)"
obj.homepage = "https://github.com/tzioup/NetworkLocationManager.spoon"
obj.license = "MIT - https://opensource.org/licenses/MIT"

--- NetworkLocationManager.locations
--- Variable
--- Table mapping macOS Network Location names to detection criteria.
---
--- Each key is a Network Location name (must match a location configured in
--- System Settings → Network). Each value is a table with:
---  * `ssids` - list of WiFi network names that should trigger this location
---  * `gateway_mac` - (optional) router MAC address as fallback detection
---
--- Example:
--- ```lua
--- spoon.NetworkLocationManager.locations = {
---   ["MyHome"] = {
---     ssids = { "HomeWiFi", "HomeWiFi_5G", "HomeWiFi_EXT" },
---     gateway_mac = "aa:bb:cc:dd:ee:ff",
---   },
---   ["Office"] = {
---     ssids = { "CorpNet" },
---   },
--- }
--- ```
---
--- To find your gateway MAC, run in Terminal:
--- `arp -n $(route -n get default | awk '/gateway:/{print $2}')`
obj.locations = {}

--- NetworkLocationManager.defaultLocation
--- Variable
--- Network Location to use when no SSID matches. Default `"Automatic"`.
obj.defaultLocation = "Automatic"

--- NetworkLocationManager.configFile
--- Variable
--- Optional path to a JSON config file. When set, locations and defaultLocation
--- are loaded from this file instead of the Lua properties above. The file is
--- re-read on every network change, so edits take effect without reloading
--- Hammerspoon.
---
--- JSON format:
--- ```json
--- {
---   "locations": {
---     "MyHome": {
---       "ssids": ["HomeWiFi", "HomeWiFi_5G"],
---       "gateway_mac": "aa:bb:cc:dd:ee:ff"
---     }
---   },
---   "default": "Automatic"
--- }
--- ```
obj.configFile = nil

--- NetworkLocationManager.pollInterval
--- Variable
--- Seconds between background checks. Default `60`. Set to `0` to disable
--- polling (rely solely on event-driven detection).
obj.pollInterval = 60

--- NetworkLocationManager.settleTime
--- Variable
--- Seconds to suppress re-evaluation after a location switch. Prevents
--- feedback loops caused by network stack resets. Default `12`.
obj.settleTime = 12

-- Internal state
local _state = {
  settling = false,
  lastTarget = nil,
  watcher = nil,
  reachWatcher = nil,
  pollTimer = nil,
  startupTimer = nil,
}

local function _nqr(msg)
  hs.alert.show("Network: " .. msg, 5)
end

local function _normalizeMac(mac)
  if not mac then return nil end
  local parts = {}
  for seg in mac:lower():gmatch("[^:]+") do
    if #seg == 1 then seg = "0" .. seg end
    table.insert(parts, seg)
  end
  return table.concat(parts, ":")
end

local function _loadConfig(self)
  if self.configFile then
    local path = self.configFile:gsub("^~", os.getenv("HOME") or "~")
    local f = io.open(path, "r")
    if not f then
      _nqr("config not found — " .. self.configFile)
      return nil
    end
    local raw = f:read("*a")
    f:close()
    local ok, cfg = pcall(hs.json.decode, raw)
    if not ok or type(cfg) ~= "table" or type(cfg.locations) ~= "table" then
      _nqr("invalid config in " .. self.configFile)
      return nil
    end
    return { locations = cfg.locations, default = cfg.default or "Automatic" }
  end
  if not self.locations or not next(self.locations) then
    _nqr("no locations configured")
    return nil
  end
  return { locations = self.locations, default = self.defaultLocation }
end

local function _currentLocation()
  local out, ok = hs.execute("scselect 2>&1")
  if not ok then return nil end
  for line in out:gmatch("[^\n]+") do
    local name = line:match("^%s*%*%s*%S+%s+%((.+)%)%s*$")
    if name then return name end
  end
  return nil
end

local function _selectLocation(target)
  if _currentLocation() == target then return true end
  local _, ok = hs.execute("scselect '" .. target .. "' 2>&1")
  if not ok then
    _nqr("scselect failed for '" .. target .. "'")
    return false
  end
  return true
end

local function _matchSSID(cfg, ssid)
  for locName, locCfg in pairs(cfg.locations) do
    if type(locCfg.ssids) == "table" then
      for _, s in ipairs(locCfg.ssids) do
        if s == ssid then return locName end
      end
    end
  end
  return nil
end

local function _getGatewayMAC()
  local gw, ok1 = hs.execute("route -n get default 2>/dev/null | awk '/gateway:/{print $2}'")
  if not ok1 or not gw or gw:match("^%s*$") then return nil end
  gw = gw:gsub("%s+", "")
  local arpOut, ok2 = hs.execute("arp -n " .. gw .. " 2>/dev/null")
  if not ok2 or not arpOut then return nil end
  local rawMac = arpOut:match("(%x+:%x+:%x+:%x+:%x+:%x+)")
  return _normalizeMac(rawMac)
end

local function _matchGatewayMAC(cfg)
  local mac = _getGatewayMAC()
  if not mac then return nil end
  for locName, locCfg in pairs(cfg.locations) do
    if _normalizeMac(locCfg.gateway_mac) == mac then
      return locName
    end
  end
  return nil
end

local function _settle(self, seconds)
  _state.settling = true
  hs.timer.doAfter(seconds, function() _state.settling = false end)
end

local function _applyTarget(self, target)
  if target == _state.lastTarget and target == _currentLocation() then return end
  _state.lastTarget = target
  _selectLocation(target)
  _settle(self, self.settleTime)
end

local function _evaluate(self)
  if _state.settling then return end
  local cfg = _loadConfig(self)
  if not cfg then return end
  local defaultLoc = cfg.default

  local ssid = hs.wifi.currentNetwork()
  if ssid then
    _applyTarget(self, _matchSSID(cfg, ssid) or defaultLoc)
    return
  end

  local gwMatch = _matchGatewayMAC(cfg)
  if gwMatch then
    _applyTarget(self, gwMatch)
    return
  end

  if _currentLocation() ~= defaultLoc then
    _settle(self, self.settleTime / 2)
    _selectLocation(defaultLoc)
    hs.timer.doAfter(5, function()
      local cfg2 = _loadConfig(self)
      if cfg2 then
        local target = _matchGatewayMAC(cfg2) or cfg2.default
        _state.lastTarget = target
        _selectLocation(target)
      end
      hs.timer.doAfter(1, function() _state.settling = false end)
    end)
  else
    _state.lastTarget = defaultLoc
  end
end

--- NetworkLocationManager:start()
--- Method
--- Start watching for WiFi changes and switching locations.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The NetworkLocationManager object
---
--- Notes:
---  * Triggers an immediate evaluation on start.
---  * If Hammerspoon lacks Location Services permission, SSID detection
---    returns nil and the Spoon falls back to gateway MAC matching.
function obj:start()
  self:stop()

  local function eval() _evaluate(self) end

  _state.watcher = hs.wifi.watcher.new(eval)
  _state.watcher:watchingFor({"SSIDChange", "powerChange", "linkChange"})
  _state.watcher:start()

  _state.reachWatcher = hs.network.reachability.forAddress("0.0.0.0")
  _state.reachWatcher:setCallback(function(_, flags)
    if flags and (flags & hs.network.reachability.flags.reachable) > 0 then
      hs.timer.doAfter(3, eval)
    end
  end)
  _state.reachWatcher:start()

  if self.pollInterval > 0 then
    _state.pollTimer = hs.timer.doEvery(self.pollInterval, eval)
  end

  _state.startupTimer = hs.timer.doAfter(3, eval)

  return self
end

--- NetworkLocationManager:stop()
--- Method
--- Stop all watchers and timers.
---
--- Parameters:
---  * None
---
--- Returns:
---  * The NetworkLocationManager object
function obj:stop()
  if _state.watcher then _state.watcher:stop(); _state.watcher = nil end
  if _state.reachWatcher then _state.reachWatcher:stop(); _state.reachWatcher = nil end
  if _state.pollTimer then _state.pollTimer:stop(); _state.pollTimer = nil end
  if _state.startupTimer then _state.startupTimer:stop(); _state.startupTimer = nil end
  _state.settling = false
  _state.lastTarget = nil
  return self
end

--- NetworkLocationManager:currentNetwork()
--- Method
--- Return the current SSID, location, and IP for debugging.
---
--- Parameters:
---  * None
---
--- Returns:
---  * A table with `ssid`, `location`, and `ip` fields.
function obj:currentNetwork()
  local ip = "unknown"
  local out = hs.execute("ifconfig en0 2>/dev/null | awk '/inet /{print $2}'")
  if out then ip = out:gsub("%s+", "") end
  return {
    ssid = hs.wifi.currentNetwork() or "(unavailable)",
    location = _currentLocation() or "(unknown)",
    ip = ip,
  }
end

function obj:init()
  hs.location.start()
  hs.timer.doAfter(5, function() hs.location.stop() end)
  return self
end

return obj
