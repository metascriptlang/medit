# Drives the desktop build with window messages sent to medic's own window and saves its screenshots.
#   pwsh scripts/desktopDrive.ps1 <exe> <file> <outDir> <step>...
# Steps: wait:<ms>  shot:<name>  key:[ctrl+][alt+][shift+]<key>[*n]  type:<text>  click:<x>,<y>  drag:<x1>,<y1>,<x2>,<y2>
# Coordinates are client pixels. The app's console output goes to <outDir>/drive.log.
param([string]$Exe, [string]$File, [string]$OutDir, [Parameter(ValueFromRemainingArguments)][string[]]$Steps)
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr SendMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint type);
  [DllImport("user32.dll")] public static extern short VkKeyScanW(char c);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] public static extern bool GetKeyboardState(byte[] s);
  [DllImport("user32.dll")] public static extern bool SetKeyboardState(byte[] s);
}
"@
[W32]::SetProcessDPIAware() | Out-Null
$root = Split-Path $PSScriptRoot
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$vks = @{ ArrowLeft = 0x25; ArrowUp = 0x26; ArrowRight = 0x27; ArrowDown = 0x28; Enter = 0x0D; Backspace = 0x08;
  Tab = 0x09; Escape = 0x1B; Home = 0x24; End = 0x23; Delete = 0x2E; PageUp = 0x21; PageDown = 0x22; Insert = 0x2D }
$extended = @(0x25, 0x26, 0x27, 0x28, 0x2E, 0x24, 0x23, 0x21, 0x22, 0x2D)
$modifiers = @{ ctrl = @(0x11, 0xA2); alt = @(0x12, 0xA4); shift = @(0x10, 0xA0) }
$p = Start-Process -FilePath $Exe -ArgumentList "`"$File`"" -WorkingDirectory $root -PassThru -RedirectStandardOutput "$OutDir\drive.log"
Start-Sleep -Milliseconds 2500
$p.Refresh()
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { "no window"; exit 1 }

function KeyParam([int]$vk, [bool]$up) {
  $lp = [int64]1 -bor ([int64][W32]::MapVirtualKeyW([uint32]$vk, 0) -shl 16)
  if ($extended -contains $vk) { $lp = $lp -bor (1 -shl 24) }
  if ($up) { $lp = $lp -bor (3 -shl 30) }
  return [IntPtr]$lp
}
function Press([int]$vk, [int]$unit) {
  [W32]::SendMessageW($h, 0x0100, [IntPtr]$vk, (KeyParam $vk $false)) | Out-Null
  if ($unit -ge 0) { [W32]::SendMessageW($h, 0x0102, [IntPtr]$unit, [IntPtr]1) | Out-Null }
  [W32]::SendMessageW($h, 0x0101, [IntPtr]$vk, (KeyParam $vk $true)) | Out-Null
  Start-Sleep -Milliseconds 15
}
function Chord([string]$spec) {
  $parts = $spec -split "\+"
  $name = $parts[-1]
  $vk = if ($vks.ContainsKey($name)) { $vks[$name] }
    elseif ($name -match '^F(\d+)$') { 0x6F + [int]$Matches[1] }
    elseif ($name.Length -eq 1) { [W32]::VkKeyScanW($name.ToLower()[0]) -band 0xff }
    else { throw "unknown key $name in $spec" }
  if ($parts.Length -eq 1) { Press $vk -1; return }
  # Ion reads modifiers with GetKeyState on the window's thread, which a sent message cannot set.
  $target = [W32]::GetWindowThreadProcessId($h, [IntPtr]::Zero)
  $self = [W32]::GetCurrentThreadId()
  if (-not [W32]::AttachThreadInput($self, $target, $true)) { throw "cannot attach to the window's input queue for $spec" }
  $state = New-Object byte[] 256
  [W32]::GetKeyboardState($state) | Out-Null
  $saved = $state.Clone()
  foreach ($m in $parts[0..($parts.Length - 2)]) {
    if (-not $modifiers.ContainsKey($m)) { throw "unknown modifier $m in $spec" }
    foreach ($k in $modifiers[$m]) { $state[$k] = 0x80 }
  }
  [W32]::SetKeyboardState($state) | Out-Null
  Press $vk -1
  [W32]::SetKeyboardState($saved) | Out-Null
  [W32]::AttachThreadInput($self, $target, $false) | Out-Null
}
function Mouse([uint32]$msg, [int]$x, [int]$y, [int]$buttons) {
  [W32]::SendMessageW($h, $msg, [IntPtr]$buttons, [IntPtr](($y -shl 16) -bor ($x -band 0xffff))) | Out-Null
}
function Shot([string]$name) {
  Start-Sleep -Milliseconds 300
  $r = New-Object W32+RECT
  [W32]::GetWindowRect($h, [ref]$r) | Out-Null
  $bmp = New-Object System.Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc()
  [W32]::PrintWindow($h, $dc, 2) | Out-Null
  $g.ReleaseHdc($dc)
  $bmp.Save("$OutDir\$name.png")
  "shot $name"
}

try {
  foreach ($step in $Steps) {
    $kind, $arg = $step -split ":", 2
    switch ($kind) {
      "wait" { Start-Sleep -Milliseconds ([int]$arg) }
      "shot" { Shot $arg }
      "type" { foreach ($c in $arg.ToCharArray()) { Press ([W32]::VkKeyScanW($c) -band 0xff) ([int]$c) } }
      "key" {
        $spec, $times = $arg -split "\*"
        for ($i = 0; $i -lt [int]($times ?? 1); $i++) { Chord $spec }
      }
      "click" { $x, $y = $arg -split ","; Mouse 0x0201 $x $y 1; Mouse 0x0202 $x $y 0; Start-Sleep -Milliseconds 30 }
      "drag" {
        $x1, $y1, $x2, $y2 = $arg -split ","
        Mouse 0x0201 $x1 $y1 1
        Mouse 0x0200 ([int](([int]$x1 + [int]$x2) / 2)) ([int](([int]$y1 + [int]$y2) / 2)) 1
        Mouse 0x0200 $x2 $y2 1
        Mouse 0x0202 $x2 $y2 0
      }
      default { throw "unknown step $step" }
    }
  }
} finally {
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
}
