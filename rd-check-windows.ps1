# 检查 RustDesk 各进程的窗口状态（可见性 / 扩展样式 / 是否进任务栏）
#
# 这个脚本要在**被控机的 Session 2（交互式桌面）**里跑，不要在 SSH 里直接跑：
#   .\rd-remote.ps1 -ScriptFile .\rd-check-windows.ps1
#
# 输出每个 RustDesk 进程的 tag（CM / TRAY / SVC / SRV / TERM / MAIN）和是否为便携实例，
# 以及它名下所有 FLUTTER_RUNNER_WIN32_WINDOW 窗口的关键属性。
#
# 关键判据（任务栏是否出按钮）：
#   顶层窗口只要 IsWindowVisible && !WS_EX_TOOLWINDOW && !WS_EX_APPWINDOW，任务栏就有按钮。
#   所以正常状态期望是：CM 窗口 ex 含 TOOLWINDOW(0x80)、不含 APPWINDOW(0x40000)，或 vis=False。
#
# 注意：CM 窗口隐藏后会被 minimize()，GetWindowRect 返回"最小化矩形"（实测 160x28），
#       不要用尺寸判断它是不是真的 CM 窗口，看 IsIconic()。

$ErrorActionPreference = 'Continue'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class RdWin {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

  public static List<string> Describe(uint targetPid) {
    var res = new List<string>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != targetPid) return true;
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      if (cls.ToString() != "FLUTTER_RUNNER_WIN32_WINDOW") return true;
      var txt = new StringBuilder(512); GetWindowText(h, txt, 512);
      RECT r; GetWindowRect(h, out r);
      int ex = GetWindowLongPtrW(h, -20).ToInt32();
      var f = new List<string>();
      if ((ex & 0x80)    != 0) f.Add("TOOLWINDOW");
      if ((ex & 0x40000) != 0) f.Add("APPWINDOW");
      if ((ex & 0x80000) != 0) f.Add("LAYERED");
      if ((ex & 0x8)     != 0) f.Add("TOPMOST");
      bool taskbar = IsWindowVisible(h) && ((ex & 0x80) == 0) && ((ex & 0x40000) == 0);
      res.Add(string.Format("hwnd={0} vis={1} iconic={2} {3}x{4} ex=0x{5:X8} [{6}] taskbar={7} title=[{8}]",
        h.ToInt64().ToString("X"), IsWindowVisible(h), IsIconic(h),
        r.Right-r.Left, r.Bottom-r.Top, ex,
        f.Count==0?"none":string.Join("|", f.ToArray()), taskbar, txt.ToString()));
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
"@ -ErrorAction Stop

"session=$((Get-Process -Id $PID).SessionId)"
""
$all = @(Get-Process -Name 'RustDesk' -ErrorAction SilentlyContinue)
"RustDesk 进程总数 = $($all.Count)"
""
$portable = @()
foreach ($p in $all) {
  $path = $null; try { $path = $p.Path } catch {}
  $cl   = $null; try { $cl   = $p.CommandLine } catch {}
  $isPortable = ($path -and $path -like '*\Temp\RustDesk\*')
  $tag = if ($cl -match '--cm') { 'CM' } elseif ($cl -match '--tray') { 'TRAY' } elseif ($cl -match '--service') { 'SVC' } elseif ($cl -match '--server') { 'SRV' } elseif ($cl -match 'terminal-helper') { 'TERM' } else { 'MAIN' }
  $mark = if ($isPortable) { 'PORTABLE' } else { 'installed' }
  "=== pid=$($p.Id) [$tag] [$mark]"
  "    path=$path"
  foreach ($w in [RdWin]::Describe([uint32]$p.Id)) { "    $w" }
  if ($isPortable) { $portable += $p.Id }
}
""
">>> 便携实例 pid: $(if ($portable.Count) { $portable -join ',' } else { '(无 —— 还没启动便携包)' })"

# hook 日志（只在设置了 RDLITE_HOOK_LOG 时才有内容）
$logs = @("$env:LOCALAPPDATA\Temp\RustDesk\config\hook.log", "$env:LOCALAPPDATA\Temp\RustDesk\hook.log")
""
"--- hook 日志 ---"
$found = $false
foreach ($lg in $logs) { if (Test-Path $lg) { $found = $true; "== $lg =="; Get-Content $lg -Tail 30 } }
if (-not $found) { "(未找到 hook.log。Hook 日志需 RDLITE_HOOK_LOG 环境变量指定路径)" }