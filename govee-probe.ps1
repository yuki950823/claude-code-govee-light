<#
  govee-probe.ps1
  ~20-min spike: does the H8022 accept ptReal / "razer" real-time segment
  packets over the LAN (UDP :4003)? If yes, we get true spatial gradients
  (app-style multi-colour) without BLE.

  Protocol (from OpenRGB GoveeController + govee2mqtt):
    binary packet : 0xBB <lenHi> <lenLo> <cmd> <payload...> <xorChecksum>
                    len = payload byte count (data after <cmd>, excl. checksum)
                    checksum = XOR of every byte before it
    wrapped as    : {"msg":{"cmd":"razer","data":{"pt":"<base64>"}}}
    enable (0xB1) : payload [0x01]            -> reference bytes BB 00 01 B1 01 0A
    led   (0xB0)  : payload [gradFlag, count, R,G,B per colour]
                    gradFlag: 0 = gradient (interpolate), 1 = discrete zones
    NOTE: device auto-disables razer mode after ~1 min with no LED data, so we
          stream the frame for a few seconds to observe.
#>
param(
  [string]$IP = '192.168.0.188',
  [int]$Seconds = 4,
  [ValidateSet('gradient','discrete')] [string]$Mode = 'gradient'
)

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition

function Xor-Bytes($list) { $c = 0; foreach ($x in $list) { $c = $c -bxor $x }; return [byte]$c }

function Build-Packet([byte]$cmd, [byte[]]$payload) {
  $pkt = New-Object System.Collections.Generic.List[byte]
  $len = $payload.Count
  $pkt.Add(0xBB)
  $pkt.Add([byte](($len -shr 8) -band 0xFF))
  $pkt.Add([byte]($len -band 0xFF))
  $pkt.Add($cmd)
  foreach ($p in $payload) { $pkt.Add([byte]$p) }
  $pkt.Add((Xor-Bytes $pkt))
  return ,$pkt.ToArray()
}

function Hex($bytes) { ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' }

function Send-Razer([string]$ip, [byte[]]$bytes, $udp) {
  $b64  = [Convert]::ToBase64String($bytes)
  $json = '{"msg":{"cmd":"razer","data":{"pt":"' + $b64 + '"}}}'
  $data = [System.Text.Encoding]::UTF8.GetBytes($json)
  $ep   = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), 4003)
  $udp.Send($data, $data.Length, $ep) | Out-Null
}

# --- stop any running status animator so it doesn't fight the razer stream ---
$genPath = Join-Path $root 'generation'
Set-Content -Path $genPath -Value ([DateTime]::UtcNow.Ticks.ToString()) -Encoding ascii

# --- build packets -----------------------------------------------------------
$enable = Build-Packet 0xB1 @(0x01)
$gradFlag = if ($Mode -eq 'discrete') { 0x01 } else { 0x00 }
# 3 distinct palette colours: red, green, blue
$led = Build-Packet 0xB0 @($gradFlag, 0x03,  0xFF,0x00,0x00,  0x00,0xFF,0x00,  0x00,0x00,0xFF)

Write-Host "Target   : $IP:4003"
Write-Host "Mode     : $Mode (gradFlag=$gradFlag)"
Write-Host "Enable   : $(Hex $enable)   (reference: BB 00 01 B1 01 0A)"
Write-Host "LED data : $(Hex $led)"
Write-Host ""

# --- send --------------------------------------------------------------------
$udp = New-Object System.Net.Sockets.UdpClient
try {
  Send-Razer $IP $enable $udp
  Start-Sleep -Milliseconds 120
  $frames = [Math]::Max(1, [int]($Seconds * 10))
  for ($i = 0; $i -lt $frames; $i++) {
    Send-Razer $IP $led $udp
    Start-Sleep -Milliseconds 100
  }
} finally { $udp.Close() }

Write-Host "Done streaming $Seconds s. WATCH THE LAMP:"
Write-Host "  * red->green->blue across the bars  = LAN ptReal WORKS (easy path open)"
Write-Host "  * one solid colour / no change      = ignored (go BLE route)"
Write-Host "Razer mode auto-disables ~1 min after the last frame; next Claude hook"
Write-Host "or 'govee-light.ps1 -Event rest' restores normal control."
