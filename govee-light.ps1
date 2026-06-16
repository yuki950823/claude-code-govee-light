<#
  govee-light.ps1
  Dispatcher: maps a Claude Code hook event to a Govee light effect.
  Stops any running animation, then launches the new effect as a detached
  background process (govee-animate.ps1) that runs until the next event.

  Usage:
    Called by Claude Code hooks (reads hook JSON from stdin), OR manually:
       powershell -NoProfile -ExecutionPolicy Bypass -File govee-light.ps1 -Event done
       powershell ... -Event permission|waiting|start
       powershell ... -Event rest     # stop animation, hold solid green
       powershell ... -Event off       # stop animation, turn light off
       powershell ... -Discover        # refresh the light's IP in govee-config.json

  Events -> effects (animated, run until the next event):
    thinking   purple flow      (UserPromptSubmit - working on your message)
    done       green breathe    (Stop / SubagentStop - task finished)
    permission pink gradient     (Notification - needs your approval)
    waiting    blue breathe      (Notification - idle, waiting on you)
    start      rainbow flow       (SessionStart - new session)
    rest       solid green        (SessionEnd - Claude exited; stop animating)
#>
param(
  [ValidateSet('done','permission','waiting','start','thinking','rest','off')]
  [string]$Event,
  [switch]$Discover
)

$ErrorActionPreference = 'SilentlyContinue'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $root 'govee-config.json'
$statesPath = Join-Path $root 'govee-states.json'
$genPath    = Join-Path $root 'generation'
$animator   = Join-Path $root 'govee-animate.ps1'
$streamer   = Join-Path $root 'govee-stream.ps1'

# ---- helpers -------------------------------------------------------------
function Get-LocalIP {
  $c = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } | Select-Object -First 1
  if ($c) { return $c.IPv4Address.IPAddress }
  return $null
}

function Invoke-Discovery {
  $localIPStr = Get-LocalIP
  if (-not $localIPStr) { return $null }
  $localIP = [System.Net.IPAddress]::Parse($localIPStr)
  $mc = [System.Net.IPAddress]::Parse('239.255.255.250')
  $udp = New-Object System.Net.Sockets.UdpClient
  try {
    $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
    $udp.Client.Bind((New-Object System.Net.IPEndPoint($localIP, 4002)))
    $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastInterface, $localIP.GetAddressBytes())
    $udp.JoinMulticastGroup($mc, $localIP)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}')
    $sendEP = New-Object System.Net.IPEndPoint($mc, 4001)
    $udp.Client.ReceiveTimeout = 2500
    for ($i = 0; $i -lt 3; $i++) {
      $udp.Send($bytes, $bytes.Length, $sendEP) | Out-Null
      try {
        while ($true) {
          $rEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
          $data = $udp.Receive([ref]$rEP)
          $json = [System.Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
          if ($json.msg.data.ip) {
            return [PSCustomObject]@{ deviceIP = $json.msg.data.ip; device = $json.msg.data.device; sku = $json.msg.data.sku }
          }
        }
      } catch {}
    }
  } finally { $udp.Close() }
  return $null
}

function Get-Config {
  if (Test-Path $configPath) {
    try { return Get-Content $configPath -Raw | ConvertFrom-Json } catch {}
  }
  return $null
}
function Save-Config($cfg) { $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8 }

function HexToRGB($h) {
  $h = $h.TrimStart('#')
  , @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
function Get-Override($evt) {
  # Per-state colour saved by the control panel (govee-states.json), or $null.
  if (Test-Path $statesPath) { try { return (Get-Content $statesPath -Raw | ConvertFrom-Json).$evt } catch {} }
  return $null
}

function Send-Govee($ip, $messages) {
  $udp = New-Object System.Net.Sockets.UdpClient
  try {
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), 4003)
    foreach ($m in $messages) {
      $b = [System.Text.Encoding]::UTF8.GetBytes($m)
      $udp.Send($b, $b.Length, $ep) | Out-Null
    }
  } finally { $udp.Close() }
}

function New-Generation {
  # Bump the generation token. Every animator (govee-animate.ps1 / govee-gradient.ps1)
  # re-reads this tiny file each loop iteration and self-exits the moment it no
  # longer matches the token it was launched with. So superseding an effect needs
  # NO process sweep — no slow WMI on the hot path — and orphaned animators can't
  # pile up (each one notices it's stale within ~one frame and quits). Returns the
  # new token. Ticks are monotonic enough that the latest writer always wins.
  $g = [DateTime]::UtcNow.Ticks.ToString()
  Set-Content -Path $genPath -Value $g -Encoding ascii
  return $g
}

function Send-BaseColor($evt, $ip) {
  # Push the effect's first frame straight from the dispatcher so the colour
  # flips immediately, instead of waiting for the detached animator's cold start.
  # The animator then takes over the pulse/flow a beat later.
  $turn = '{"msg":{"cmd":"turn","data":{"value":1}}}'
  $rgb = $null
  $ov = Get-Override $evt
  if ($ov) {
    # Honour a colour saved in the control panel so the instant first frame
    # matches the saved effect (no flash of the old hardcoded colour).
    if ($ov.type -eq 'gradient') {
      $a = HexToRGB $ov.a; $b = HexToRGB $ov.b
      # the animator starts at phase 0 -> the A/B midpoint, so seed the same
      # frame here for a seamless handoff.
      $rgb = @([int](($a[0] + $b[0]) / 2), [int](($a[1] + $b[1]) / 2), [int](($a[2] + $b[2]) / 2))
    }
    elseif ($ov.type -eq 'solid') { $rgb = HexToRGB $ov.color }
    elseif ($ov.type -eq 'stream' -and $ov.colors) {
      # Seed the gradient's first stop as an instant single-colour frame; the
      # streamer enables razer mode and takes over the spatial gradient a beat
      # later (same latency trick as the other effects).
      $rgb = HexToRGB ($ov.colors[0])
    }
  }
  if (-not $rgb) {
    $rgb = switch ($evt) {
      'thinking'   { @(200, 0, 255) }
      'permission' { @(255, 162, 154) }
      'waiting'    { @(0, 90, 255) }
      'start'      { @(255, 0, 0) }
      default      { @(0, 255, 0) }
    }
  }
  $color = '{"msg":{"cmd":"colorwc","data":{"color":{"r":' + [int]$rgb[0] + ',"g":' + [int]$rgb[1] + ',"b":' + [int]$rgb[2] + '},"colorTemInKelvin":0}}}'
  Send-Govee $ip @($turn, $color)
}

function Start-Animator($evt, $ip, $gen) {
  # Single quoted arg string: PS 5.1 Start-Process does NOT quote array elements,
  # so the script path (which contains a space) must be quoted explicitly.
  $ov = Get-Override $evt
  if ($ov -and $ov.type -eq 'stream' -and $ov.colors) {
    # Spatial gradient: drive govee-stream.ps1 (ptReal/razer) instead of the
    # single-colour govee-animate.ps1. Colours join into a comma list (hex, no
    # spaces -> safe as one bare arg).
    $colors = ($ov.colors -join ',')
    $spd  = if ($ov.speed) { ([double]$ov.speed).ToString([System.Globalization.CultureInfo]::InvariantCulture) } else { '0.05' }
    $flow = if ($ov.flow -eq $false -or $ov.flow -eq 0) { 0 } else { 1 }
    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$streamer`" -IP $ip -Colors $colors -Speed $spd -Flow $flow -Gen $gen"
  } else {
    $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$animator`" -Event $evt -IP $ip -Gen $gen"
  }
  Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList $argString | Out-Null
}

# ---- discovery mode ------------------------------------------------------
if ($Discover) {
  $d = Invoke-Discovery
  if ($d) { Save-Config $d; "Discovered $($d.sku) at $($d.deviceIP)"; exit 0 }
  "No Govee device found on the LAN."; exit 1
}

# ---- determine event (hook stdin OR -Event param) ------------------------
if (-not $Event) {
  $raw = [Console]::In.ReadToEnd()
  if ($raw) {
    try {
      $hook = $raw | ConvertFrom-Json
      switch ($hook.hook_event_name) {
        'Stop'             { $Event = 'done' }
        'SubagentStop'     { $Event = 'done' }
        'SessionStart'     { $Event = 'start' }
        'SessionEnd'       { $Event = 'rest' }
        'UserPromptSubmit' { $Event = 'thinking' }
        'PostToolUse'      { $Event = 'thinking' }
        'Notification' {
          $msg = "$($hook.message)".ToLower()
          if ($msg -match 'permission|approve|allow|wants to|use the') { $Event = 'permission' }
          else { $Event = 'waiting' }
        }
      }
    } catch {}
  }
}
if (-not $Event) { exit 0 }

# ---- resolve device ------------------------------------------------------
$cfg = Get-Config
if (-not $cfg -or -not $cfg.deviceIP) {
  $cfg = Invoke-Discovery
  if ($cfg) { Save-Config $cfg } else { exit 0 }
}
$ip = $cfg.deviceIP

# ---- act -----------------------------------------------------------------
# Order matters for latency: push the new colour onto the wire FIRST, so the
# light changes the instant this (cold-started) dispatcher is alive. The
# old-animator sweep and the new-animator spawn happen after, off the path the
# eye is waiting on.
switch ($Event) {
  'off'  { New-Generation | Out-Null; Send-Govee $ip @('{"msg":{"cmd":"turn","data":{"value":0}}}') }
  'rest' { New-Generation | Out-Null; Send-Govee $ip @('{"msg":{"cmd":"turn","data":{"value":1}}}', '{"msg":{"cmd":"colorwc","data":{"color":{"r":0,"g":255,"b":0},"colorTemInKelvin":0}}}') }
  default {
    $gen = New-Generation            # 1. supersede the old effect (it self-exits)
    Send-BaseColor $Event $ip        # 2. instant correct colour
    Start-Animator $Event $ip $gen   # 3. start the new pulse/flow
  }
}
exit 0
