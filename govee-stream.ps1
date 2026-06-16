<#
  govee-stream.ps1
  Streaming SPATIAL gradient animator for the H8022 (DreamView/Razer device).
  Unlike the single-colour effects in govee-animate.ps1 (which send one `colorwc`
  per frame), this paints the whole bar with many colours at once using the
  ptReal / "razer" real-time segment protocol over the LAN — the app-style look.

  How it flows: the stops are treated as a LOOPING gradient (stop N wraps back to
  stop 0). Each frame we sample that loop at $Res evenly-spaced points, offset by
  a phase that advances every frame, and send those $Res colours as one 0xB0 frame
  with gradient-flag 0 (the lamp interpolates them across its physical segments).
  Advancing the phase scrolls the whole gradient along the bar.

  ptReal packet : 0xBB <lenHi> <lenLo> <cmd> <payload...> <xorChecksum>
                  len = payload byte count after <cmd>; checksum = XOR of all prior bytes
                  wrapped as {"msg":{"cmd":"razer","data":{"pt":"<base64>"}}}
                  enable 0xB1 [0x01]; LED 0xB0 [gradFlag, count, R,G,B per colour]
  Razer mode auto-disables ~1 min after the last LED frame, so we stream
  continuously and re-assert enable periodically.

    powershell ... -File govee-stream.ps1 -IP 192.168.0.188 -Colors "8000FF,FF00AA,00E0FF" -Speed 0.05 -Flow 1

  Self-exits the instant the generation token (.govee\generation) changes, exactly
  like govee-animate.ps1 — so the dispatcher/control-panel supersede it with no
  process sweep.
#>
param(
  [Parameter(Mandatory = $true)][string]$IP,
  [Parameter(Mandatory = $true)][string]$Colors,   # comma-separated hex stops, e.g. "FF0000,00FF00,0000FF"
  [double]$Speed = 0.05,                            # phase advance per frame (0 with -Flow 0 = static)
  [int]$Flow = 1,                                   # 1 = scroll, 0 = hold still
  [int]$Res = 8,                                    # palette colours sent per frame (interpolation resolution)
  [int]$Sleep = 100,                                # ms between frames (~10 fps)
  [string]$Gen = ''
)
$ErrorActionPreference = 'SilentlyContinue'

$genPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'generation'
function Get-Gen { try { (Get-Content $genPath -Raw -ErrorAction SilentlyContinue).Trim() } catch { $null } }

# ---- colour helpers ---------------------------------------------------------
function Hex2RGB([string]$h) {
  $h = $h.TrimStart('#')
  , @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
$stops = @()
foreach ($c in ($Colors -split ',')) { $c = $c.Trim(); if ($c) { $stops += , (Hex2RGB $c) } }
if ($stops.Count -eq 0) { exit 0 }
if ($stops.Count -eq 1) { $stops += , $stops[0] }   # a single stop = solid (still valid)
$n = $stops.Count

# Sample the LOOPING gradient at pos in [0,1): segment i -> (i+1)%n, so it wraps
# seamlessly and a scrolling phase never shows a seam.
function Sample([double]$pos) {
  $pos = $pos - [math]::Floor($pos)          # wrap into [0,1)
  $x = $pos * $n
  $i = [int][math]::Floor($x)
  $f = $x - $i
  $a = $stops[$i % $n]
  $b = $stops[($i + 1) % $n]
  , @([int]($a[0] + ($b[0] - $a[0]) * $f),
      [int]($a[1] + ($b[1] - $a[1]) * $f),
      [int]($a[2] + ($b[2] - $a[2]) * $f))
}

# ---- ptReal packet builders (verified against OpenRGB reference in probe) ----
function Xor-Bytes($list) { $c = 0; foreach ($x in $list) { $c = $c -bxor $x }; return [byte]$c }
function Build-Packet([byte]$cmd, [byte[]]$payload) {
  $pkt = New-Object System.Collections.Generic.List[byte]
  $len = $payload.Count
  $pkt.Add(0xBB); $pkt.Add([byte](($len -shr 8) -band 0xFF)); $pkt.Add([byte]($len -band 0xFF)); $pkt.Add($cmd)
  foreach ($p in $payload) { $pkt.Add([byte]$p) }
  $pkt.Add((Xor-Bytes $pkt))
  return , $pkt.ToArray()
}
$enable = Build-Packet 0xB1 @(0x01)

$udp = New-Object System.Net.Sockets.UdpClient
$ep  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($IP), 4003)
function Send-Razer([byte[]]$bytes) {
  $b64  = [Convert]::ToBase64String($bytes)
  $json = '{"msg":{"cmd":"razer","data":{"pt":"' + $b64 + '"}}}'
  $data = [System.Text.Encoding]::UTF8.GetBytes($json)
  $udp.Send($data, $data.Length, $ep) | Out-Null
}

# make sure it's on, then enter razer mode
Send-Razer (Build-Packet 0xB1 @(0x01)) | Out-Null
$udpTurn = [System.Text.Encoding]::UTF8.GetBytes('{"msg":{"cmd":"turn","data":{"value":1}}}')
$udp.Send($udpTurn, $udpTurn.Length, $ep) | Out-Null
Send-Razer $enable

$phase = 0.0
$frame = 0
while ($true) {
  # Self-exit the moment a newer effect supersedes us (same contract as the other
  # animators: only a confirmed *different* non-empty token quits us, so a manual
  # run with no -Gen streams forever).
  if ($Gen) { $g = Get-Gen; if ($g -and $g -ne $Gen) { break } }

  # Re-assert enable every ~5 s so razer mode never lapses (auto-disables after 1
  # min of no LED data; cheap insurance against a dropped UDP frame).
  if (($frame % 50) -eq 0) { Send-Razer $enable }

  # Build one LED frame: $Res colours sampled along the scrolling loop.
  $payload = New-Object System.Collections.Generic.List[byte]
  $payload.Add(0x00)                 # gradFlag 0 = interpolate palette across segments
  $payload.Add([byte]$Res)
  for ($k = 0; $k -lt $Res; $k++) {
    $rgb = Sample (($k / [double]$Res) + $phase)
    $payload.Add([byte]([math]::Max(0, [math]::Min(255, $rgb[0]))))
    $payload.Add([byte]([math]::Max(0, [math]::Min(255, $rgb[1]))))
    $payload.Add([byte]([math]::Max(0, [math]::Min(255, $rgb[2]))))
  }
  Send-Razer (Build-Packet 0xB0 $payload.ToArray())

  if ($Flow -ne 0) { $phase += $Speed }
  $frame++
  Start-Sleep -Milliseconds $Sleep
}
$udp.Close()
