<#
  govee-animate.ps1
  Runs ONE continuous lighting effect until the process is killed.
  Launched (detached, hidden) by govee-light.ps1; not called directly by hooks.

  Effects:
    done       green breathe  (slow)
    waiting    blue breathe   (slow)
    permission pink gradient   (FFA29A <-> FFCDA9)
    start      rainbow flow
    thinking   purple flow     (Claude is working on your message)
#>
param(
  [Parameter(Mandatory = $true)][string]$Event,
  [Parameter(Mandatory = $true)][string]$IP,
  [string]$Gen = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$udp = New-Object System.Net.Sockets.UdpClient
$ep  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($IP), 4003)
$genPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'generation'
function Get-Gen { try { (Get-Content $genPath -Raw -ErrorAction SilentlyContinue).Trim() } catch { $null } }

function Send-Raw($j) { $b = [Text.Encoding]::UTF8.GetBytes($j); $udp.Send($b, $b.Length, $ep) | Out-Null }
function Send-RGB($r, $g, $b) {
  Send-Raw ('{"msg":{"cmd":"colorwc","data":{"color":{"r":' + [int]$r + ',"g":' + [int]$g + ',"b":' + [int]$b + '},"colorTemInKelvin":0}}}')
}
function HSVtoRGB($h, $s, $v) {
  $i = [int]([math]::Floor($h / 60)) % 6
  $f = $h / 60 - [math]::Floor($h / 60)
  $p = $v * (1 - $s); $q = $v * (1 - $f * $s); $t = $v * (1 - (1 - $f) * $s)
  switch ($i) {
    0 { $r = $v; $g = $t; $b = $p; break }
    1 { $r = $q; $g = $v; $b = $p; break }
    2 { $r = $p; $g = $v; $b = $t; break }
    3 { $r = $p; $g = $q; $b = $v; break }
    4 { $r = $t; $g = $p; $b = $v; break }
    5 { $r = $v; $g = $p; $b = $q; break }
  }
  return , @([int]($r * 255), [int]($g * 255), [int]($b * 255))
}

function HexToRGB($h) {
  $h = $h.TrimStart('#')
  , @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

# Per-state override authored by the control panel (govee-states.json). If the
# current event has an entry, it wins over the hardcoded effects below — that's
# how the HTML "Save state" closes the loop into the hooks.
$override = $null
$statesPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'govee-states.json'
if (Test-Path $statesPath) { try { $override = (Get-Content $statesPath -Raw | ConvertFrom-Json).$Event } catch {} }
$ovA = $null; $ovB = $null
if ($override -and $override.type -eq 'gradient') { $ovA = HexToRGB $override.a; $ovB = HexToRGB $override.b }

# make sure the light is on
Send-Raw '{"msg":{"cmd":"turn","data":{"value":1}}}'

$phase = 0.0
$hue   = 0.0
while ($true) {
  # Self-exit the instant a newer effect supersedes us (token bumped by the
  # dispatcher / control panel). Only acts on a confirmed different token, so a
  # transient/empty read or a manual run with no -Gen keeps animating.
  if ($Gen) { $g = Get-Gen; if ($g -and $g -ne $Gen) { break } }
  if ($override -and $override.type -eq 'gradient') {
    $t = ([math]::Sin($phase) + 1) / 2
    Send-RGB ($ovA[0] + ($ovB[0] - $ovA[0]) * $t) ($ovA[1] + ($ovB[1] - $ovA[1]) * $t) ($ovA[2] + ($ovB[2] - $ovA[2]) * $t)
    $phase += [double]$override.speed
    Start-Sleep -Milliseconds 80
    continue
  }
  if ($override -and $override.type -eq 'solid') {
    $c = HexToRGB $override.color
    Send-RGB $c[0] $c[1] $c[2]
    Start-Sleep -Milliseconds 500
    continue
  }
  switch ($Event) {
    'permission' {
      # pink gradient flow - solid colour easing between FFA29A and FFCDA9
      $t = ([math]::Sin($phase) + 1) / 2
      Send-RGB 255 (162 + 43 * $t) (154 + 15 * $t)
      $phase += 0.12
      Start-Sleep -Milliseconds 80
    }
    'waiting' {
      # blue breathe - gentle
      $f = 0.12 + 0.88 * (([math]::Sin($phase) + 1) / 2)
      Send-RGB 0 (90 * $f) (255 * $f)
      $phase += 0.16
      Start-Sleep -Milliseconds 80
    }
    'start' {
      # rainbow flow
      $rgb = HSVtoRGB ($hue % 360) 1 1
      Send-RGB $rgb[0] $rgb[1] $rgb[2]
      $hue += 7
      Start-Sleep -Milliseconds 75
    }
    'thinking' {
      # purple<->magenta flow - actively working on your message
      $h = 270 + 50 * (([math]::Sin($phase) + 1) / 2)
      $rgb = HSVtoRGB $h 1 1
      Send-RGB $rgb[0] $rgb[1] $rgb[2]
      $phase += 0.22
      Start-Sleep -Milliseconds 75
    }
    default {
      # done -> green breathe - calm resting state
      $f = 0.12 + 0.88 * (([math]::Sin($phase) + 1) / 2)
      Send-RGB 0 (255 * $f) 0
      $phase += 0.14
      Start-Sleep -Milliseconds 80
    }
  }
}
