<#
  govee-gradient.ps1
  Generalised two-colour gradient animator. Eases a solid colour back and forth
  between hex A and hex B. Used by the control panel (govee-server.ps1) for live
  preview while you drag the wheel; the saved version is replayed by the hooks
  via govee-animate.ps1 reading govee-states.json.

    powershell ... -File govee-gradient.ps1 -IP 192.168.0.188 -A FFA29A -B FFCDA9 -Speed 0.12
#>
param(
  [Parameter(Mandatory = $true)][string]$IP,
  [Parameter(Mandatory = $true)][string]$A,
  [Parameter(Mandatory = $true)][string]$B,
  [double]$Speed = 0.12,
  [int]$Sleep = 80,
  [string]$Gen = ''
)
$ErrorActionPreference = 'SilentlyContinue'
$genPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'generation'
function Get-Gen { try { (Get-Content $genPath -Raw -ErrorAction SilentlyContinue).Trim() } catch { $null } }
function Hex($h) {
  $h = $h.TrimStart('#')
  , @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
$ca = Hex $A
$cb = Hex $B
$udp = New-Object System.Net.Sockets.UdpClient
$ep  = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($IP), 4003)
function Send-Raw($j) { $bytes = [Text.Encoding]::UTF8.GetBytes($j); $udp.Send($bytes, $bytes.Length, $ep) | Out-Null }
function Send-RGB($r, $g, $b) {
  Send-Raw ('{"msg":{"cmd":"colorwc","data":{"color":{"r":' + [int]$r + ',"g":' + [int]$g + ',"b":' + [int]$b + '},"colorTemInKelvin":0}}}')
}
Send-Raw '{"msg":{"cmd":"turn","data":{"value":1}}}'
$phase = 0.0
while ($true) {
  if ($Gen) { $g = Get-Gen; if ($g -and $g -ne $Gen) { break } }
  $t = ([math]::Sin($phase) + 1) / 2
  Send-RGB ($ca[0] + ($cb[0] - $ca[0]) * $t) ($ca[1] + ($cb[1] - $ca[1]) * $t) ($ca[2] + ($cb[2] - $ca[2]) * $t)
  $phase += $Speed
  Start-Sleep -Milliseconds $Sleep
}
