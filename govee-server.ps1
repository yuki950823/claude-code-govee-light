<#
  govee-server.ps1
  Tiny local backend for the Govee control panel. Serves govee-control.html and
  relays the page's commands to the lamp over the LAN UDP API (browsers can't
  send UDP themselves). Single-user, single-threaded — plenty for one panel.

    powershell -NoProfile -ExecutionPolicy Bypass -File govee-server.ps1 [-Port 8099]

  Endpoints:
    GET  /                serve the control panel
    GET  /api/states      { ip, states }  (current govee-states.json)
    POST /api/color       { r,g,b }              -> solid colour now
    POST /api/gradient    { a,b,speed }           -> live 2-stop colour animator
    POST /api/stream      { colors:[..],speed,flow } -> live spatial gradient (ptReal)
    POST /api/power       { on:true|false }
    POST /api/stop        {}                       -> stop any animation
    POST /api/save        { state,type,a,b,speed | state,type,color | state,type:stream,colors,speed,flow } -> govee-states.json
#>
param([int]$Port = 8099)
$ErrorActionPreference = 'Stop'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath = Join-Path $root 'govee-config.json'
$statesPath = Join-Path $root 'govee-states.json'
$genPath    = Join-Path $root 'generation'
$htmlPath   = Join-Path $root 'govee-control.html'
$gradient   = Join-Path $root 'govee-gradient.ps1'
$streamer   = Join-Path $root 'govee-stream.ps1'

function Get-IP {
  if (Test-Path $configPath) { try { return (Get-Content $configPath -Raw | ConvertFrom-Json).deviceIP } catch {} }
  return $null
}
$script:ip = Get-IP
$script:gradientRunning = $false
$udp = New-Object System.Net.Sockets.UdpClient

function Send-Govee($messages) {
  if (-not $script:ip) { return }
  $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($script:ip), 4003)
  foreach ($m in $messages) { $b = [Text.Encoding]::UTF8.GetBytes($m); $udp.Send($b, $b.Length, $ep) | Out-Null }
}
function Send-Color($r, $g, $b) {
  Send-Govee @('{"msg":{"cmd":"turn","data":{"value":1}}}',
    ('{"msg":{"cmd":"colorwc","data":{"color":{"r":' + [int]$r + ',"g":' + [int]$g + ',"b":' + [int]$b + '},"colorTemInKelvin":0}}}'))
}
function New-Generation {
  # Same generation token the hooks use: bumping it makes every running animator
  # (hook or panel) self-exit within one frame — no process sweep needed.
  $g = [DateTime]::UtcNow.Ticks.ToString()
  Set-Content -Path $genPath -Value $g -Encoding ascii
  return $g
}
function Start-Gradient($a, $b, $speed) {
  $gen = New-Generation
  $spd = ([double]$speed).ToString([System.Globalization.CultureInfo]::InvariantCulture)
  $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$gradient`" -IP $script:ip -A $a -B $b -Speed $spd -Gen $gen"
  Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList $argString | Out-Null
}
function Start-Stream($colors, $speed, $flow) {
  # Spatial gradient live preview: drive govee-stream.ps1 (ptReal/razer). Same
  # generation-token handoff as Start-Gradient — bump, then launch tagged.
  $gen = New-Generation
  $spd = ([double]$speed).ToString([System.Globalization.CultureInfo]::InvariantCulture)
  $col = ($colors -join ',')
  $fl  = if ($flow) { 1 } else { 0 }
  $argString = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$streamer`" -IP $script:ip -Colors $col -Speed $spd -Flow $fl -Gen $gen"
  Start-Process -FilePath 'powershell' -WindowStyle Hidden -ArgumentList $argString | Out-Null
}
function Write-Json($res, $obj) {
  $json = ($obj | ConvertTo-Json -Compress -Depth 6)
  $buf = [Text.Encoding]::UTF8.GetBytes($json)
  $res.ContentType = 'application/json; charset=utf-8'
  $res.OutputStream.Write($buf, 0, $buf.Length)
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() }
catch { Write-Host "Could not start listener on port $Port. $($_.Exception.Message)"; exit 1 }
Write-Host "Govee control panel -> http://localhost:$Port/   (lamp IP: $script:ip)   Ctrl+C to stop."

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  $req = $ctx.Request
  $res = $ctx.Response
  try {
    $path = $req.Url.AbsolutePath
    if ($req.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
      # Serve the raw UTF-8 bytes as-is. (PS 5.1 Get-Content -Raw would decode a
      # BOM-less UTF-8 file as ANSI and mangle ·, —, … into mojibake.)
      $buf = [System.IO.File]::ReadAllBytes($htmlPath)
      $res.ContentType = 'text/html; charset=utf-8'
      $res.OutputStream.Write($buf, 0, $buf.Length)
    }
    elseif ($req.HttpMethod -eq 'GET' -and $path -eq '/api/states') {
      $obj = $null
      if (Test-Path $statesPath) { try { $obj = Get-Content $statesPath -Raw | ConvertFrom-Json } catch {} }
      Write-Json $res @{ ip = $script:ip; states = $obj }
    }
    elseif ($req.HttpMethod -eq 'POST') {
      $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
      $body = $reader.ReadToEnd(); $reader.Close()
      $d = if ($body) { $body | ConvertFrom-Json } else { $null }
      switch ($path) {
        '/api/color' {
          New-Generation | Out-Null   # supersede any running animator; solid colour holds
          Send-Color $d.r $d.g $d.b
          Write-Json $res @{ ok = $true }
        }
        '/api/gradient' {
          Start-Gradient $d.a $d.b $d.speed
          Write-Json $res @{ ok = $true }
        }
        '/api/stream' {
          Start-Stream $d.colors $d.speed $d.flow
          Write-Json $res @{ ok = $true }
        }
        '/api/power' {
          New-Generation | Out-Null
          if ($d.on) { Send-Govee @('{"msg":{"cmd":"turn","data":{"value":1}}}') }
          else       { Send-Govee @('{"msg":{"cmd":"turn","data":{"value":0}}}') }
          Write-Json $res @{ ok = $true }
        }
        '/api/stop' {
          New-Generation | Out-Null
          Write-Json $res @{ ok = $true }
        }
        '/api/save' {
          $ht = @{}
          if (Test-Path $statesPath) {
            try {
              $existing = Get-Content $statesPath -Raw | ConvertFrom-Json
              if ($existing) { foreach ($p in $existing.PSObject.Properties) { $ht[$p.Name] = $p.Value } }
            } catch {}
          }
          if     ($d.type -eq 'gradient') { $ht[$d.state] = @{ type = 'gradient'; a = $d.a; b = $d.b; speed = $d.speed } }
          elseif ($d.type -eq 'stream')   { $ht[$d.state] = @{ type = 'stream'; colors = @($d.colors); speed = $d.speed; flow = [bool]$d.flow } }
          else                            { $ht[$d.state] = @{ type = 'solid'; color = $d.color } }
          ($ht | ConvertTo-Json -Depth 6) | Set-Content -Path $statesPath -Encoding UTF8
          Write-Json $res @{ ok = $true; saved = $d.state }
        }
        default { $res.StatusCode = 404; Write-Json $res @{ error = 'not found' } }
      }
    }
    else { $res.StatusCode = 404 }
  } catch {
    $res.StatusCode = 500
    try { Write-Json $res @{ error = "$($_.Exception.Message)" } } catch {}
  } finally {
    $res.OutputStream.Close()
  }
}
