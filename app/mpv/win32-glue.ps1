# Glue the mpv own-window behind the transparent Electron app window.
# Called by main.cjs via powershell -File. Finds the mpv window by its unique
# title token and moves/resizes it (or hides/shows it) so the borderless mpv
# surface sits exactly behind the always-on-top app console.
#
# Z-order fix (v2.0.129): When -OwnerHwnd is provided, SetWindowPos places mpv
# directly BEHIND the Electron owner window (used as the 'after' parameter),
# with SWP_NOACTIVATE only — no SWP_NOZORDER, so the Z-order IS enforced.
param(
  [string]$Token = '',
  [int]$X = 0,
  [int]$Y = 0,
  [int]$W = 0,
  [int]$H = 0,
  [string]$Action = 'move',
  [long]$RawHwnd = 0,
  [long]$OwnerHwnd = 0
)

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class MpvWin {
  public delegate bool EnumProc(IntPtr h, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr lp);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@

Add-Type -TypeDefinition $code -ErrorAction Stop

$found = [IntPtr]::Zero
if ($RawHwnd -ne 0) {
  $found = [IntPtr]::new($RawHwnd)
} else {
  $del = [MpvWin+EnumProc]{ param($h, $p)
    if (-not [MpvWin]::IsWindowVisible($h)) { return $true }
    $sb = New-Object System.Text.StringBuilder 256
    [MpvWin]::GetWindowText($h, $sb, 256) | Out-Null
    if ($sb.ToString() -like "*$Token*") { $script:found = $h; return $false }
    return $true
  }
  [MpvWin]::EnumWindows($del, [IntPtr]::Zero) | Out-Null
}

if ($found -eq [IntPtr]::Zero) { exit 1 }

if ($Action -eq 'hide') { [void][MpvWin]::ShowWindow($found, 0); Write-Output ([int]$found); exit 0 }
if ($Action -eq 'show') { [void][MpvWin]::ShowWindow($found, 1); Write-Output ([int]$found); exit 0 }

# move/resize WITH Z-order enforcement:
#   - If OwnerHwnd is given: place mpv directly behind the Electron window
#     (SWP_NOACTIVATE only — do NOT use SWP_NOZORDER so Z-order takes effect)
#   - If OwnerHwnd not given: fallback to SWP_NOZORDER | SWP_NOACTIVATE (no change)
$after = [IntPtr]::Zero
$flags = 0x0004 -bor 0x0010  # SWP_NOZORDER | SWP_NOACTIVATE (fallback)
if ($OwnerHwnd -ne 0) {
  $after = [IntPtr]::new($OwnerHwnd)
  $flags = 0x0010            # SWP_NOACTIVATE only — enforce Z-order via $after
}
[void][MpvWin]::SetWindowPos($found, $after, $X, $Y, $W, $H, $flags)
Write-Output ([int]$found)
