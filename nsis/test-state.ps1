#Requires -Version 5.1
<#
  验证「并发实例 / 状态交接」逻辑（用极小载荷，几秒出结果）

  覆盖两件事：
    1) 状态交接（state.ini）—— 第一个实例记住正式版是否在跑，
       后续实例（含新版本接管后的实例）能从文件继承，不乱覆盖成 0；
       跨开机遗留的陈旧状态会被丢弃。
    2) 互斥分支 —— 同 GUID 重复运行命中互斥直接退出；
       不同 GUID（模拟新版本）会先杀掉旧实例再接管，且不会杀掉自己。

  用法：pwsh nsis\test-state.ps1 [-NsisExe <path>]
#>
[CmdletBinding()]
param([string]$NsisExe)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if (-not $NsisExe) { $NsisExe = 'D:\App\开发工具\VNISEdit\NSIS\3.10.3.0.x64\makensis.exe' }
if (-not (Test-Path $NsisExe)) { throw "makensis 不存在: $NsisExe" }

$work = Join-Path $here '_state'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null

$bad = 0
function Check([bool]$ok, [string]$label, [string]$detail = '') {
  if (-not $ok) { $script:bad++ }
  $color = if ($ok) { 'DarkGray' } else { 'Red' }
  Write-Host ("   {0} {1} {2}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $label, $detail) -ForegroundColor $color
}

function New-Nsi([string]$outExe, [string]$srcPath, [string]$template) {
  $script = $template.Replace('OUT_EXE', $outExe).Replace('OUT_TXT', ($outExe -replace '\.exe$', '.txt'))
  [IO.File]::WriteAllText($srcPath, $script, (New-Object Text.UTF8Encoding($true)))
  & $NsisExe /V1 $srcPath 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "makensis 编译失败: $srcPath" }
}

# =====================================================================
# 1. 状态交接（直接编译并运行 nsis\test-state.nsi）
# =====================================================================
Write-Host '1) 状态交接 ReadState / WriteState / ClearState' -ForegroundColor Cyan

$stateExe = Join-Path $work 'state-test.exe'
$stateLog = Join-Path $work 'state.txt'
$stateDir = Join-Path $work 'statedir'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

& $NsisExe /V1 "/DOUT_FILE=$stateExe" "/DLOG=$stateLog" "/DSTATE_DIR=$stateDir" `
  (Join-Path $here 'test-state.nsi') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makensis 编译 test-state.nsi 失败' }

if (Test-Path $stateLog) { Remove-Item $stateLog -Force }
Start-Process -FilePath $stateExe -Wait
Start-Sleep -Milliseconds 200

if (-not (Test-Path $stateLog)) { throw "没有产生测试输出: $stateLog" }
$lines = Get-Content $stateLog
foreach ($l in $lines) {
  if ($l -match '^\[(PASS|FAIL)\]\s+(.*)$') {
    Check ($Matches[1] -eq 'PASS') $Matches[2]
  }
}
Check (@($lines | Where-Object { $_ -match '^\[FAIL\]' }).Count -eq 0) '状态交接无失败项'

# =====================================================================
# 2. 互斥分支（同 GUID / 不同 GUID）
# =====================================================================
Write-Host "`n2) 并发互斥分支" -ForegroundColor Cyan

$mutex = @'
Unicode true
!include "LogicLib.nsh"
!ifndef LAUNCH_GUID
  !define LAUNCH_GUID "probe"
!endif
!ifndef LAUNCHER_IMAGE
  !define LAUNCHER_IMAGE "probe-mutex.exe"
!endif
Name "probe-mutex"
OutFile "OUT_EXE"
RequestExecutionLevel user
SilentInstall silent
Function .onInit
  System::Call 'kernel32::GetCurrentProcessId() i .r5'
  StrCpy $8 "OUT_TXT.$5"
  System::Call 'kernel32::SetLastError(i 0)'
  System::Call 'kernel32::CreateMutexW(p 0, i 0, w "RustDeskLitePortableLauncher_${LAUNCH_GUID}") i .r4 ?e'
  Pop $6
  FileOpen $9 "$8" w
  FileWrite $9 "err=$6 "
  ${If} $6 == 183
    FileWrite $9 "HIT$\r$\n"
    FileClose $9
    System::Call 'kernel32::CloseHandle(p r4)'
    Quit
  ${EndIf}
  FileWrite $9 "OWNED$\r$\n"
  nsExec::ExecToStack 'taskkill /F /T /FI "IMAGENAME eq ${LAUNCHER_IMAGE}" /FI "PID ne $5"'
  Pop $1
  Pop $2
  FileWrite $9 "taskkill_rc=$1$\r$\n"
  Sleep 300
  FileWrite $9 "alive$\r$\n"
  FileClose $9
FunctionEnd
Section
  Sleep 2500
SectionEnd
'@

# 两个不同 GUID 的版本；物理文件名不同，但内部 LAUNCHER_IMAGE 相同
# （真实场景里 exe 名字是固定的，只有 GUID 随编译变化）
$d1 = Join-Path $work 'v1'; $d2 = Join-Path $work 'v2'
New-Item -ItemType Directory -Path $d1, $d2 -Force | Out-Null
$exeA = Join-Path $d1 'probe-mutex.exe'
$exeB = Join-Path $d2 'probe-mutex.exe'
$srcA = Join-Path $work 'a.nsi'; $srcB = Join-Path $work 'b.nsi'
$tplA = $mutex.Replace('OUT_TXT', ($exeA -replace '\.exe$', '.log'))
$tplB = $mutex.Replace('OUT_TXT', ($exeB -replace '\.exe$', '.log'))
[IO.File]::WriteAllText($srcA, $tplA.Replace('OUT_EXE', $exeA), (New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText($srcB, $tplB.Replace('OUT_EXE', $exeB), (New-Object Text.UTF8Encoding($true)))
& $NsisExe /V1 /DLAUNCH_GUID=guidA $srcA 2>&1 | Out-Null
& $NsisExe /V1 /DLAUNCH_GUID=guidB $srcB 2>&1 | Out-Null

# --- 2a. 同 GUID 双击两次：一 OWNED 一 HIT，且不自杀 ---
foreach ($f in @(Get-ChildItem -Path $d1 -Filter '*.log*')) { Remove-Item -Path $f.FullName -Force }
Start-Process -FilePath $exeA
Start-Sleep -Milliseconds 500
Start-Process -FilePath $exeA
Start-Sleep -Seconds 4
$logs = @(Get-ChildItem -Path $d1 -Filter '*.log*')
$hit = @($logs | Where-Object { (Get-Content $_.FullName -Raw) -match 'HIT' }).Count
$owned = @($logs | Where-Object { (Get-Content $_.FullName -Raw) -match 'OWNED' }).Count
Check ($hit -eq 1 -and $owned -eq 1) '同 GUID：一个 OWNED、一个 HIT MUTEX' "hit=$hit owned=$owned"
$aliveLine = @($logs | Where-Object { (Get-Content $_.FullName -Raw) -match 'alive' }).Count
Check ($aliveLine -eq 1) '同 GUID：OWNED 实例没被自己的 taskkill 杀掉'

# --- 2b. 不同 GUID：新版本杀掉旧实例并接管 ---
foreach ($f in @(Get-ChildItem -Path $d2 -Filter '*.log*')) { Remove-Item -Path $f.FullName -Force }
Start-Process -FilePath $exeA          # 旧版本
Start-Sleep -Seconds 1
$oldPid = @(Get-Process -Name 'probe-mutex' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Start-Process -FilePath $exeB          # 新版本（不同 GUID）
Start-Sleep -Seconds 4
$newLog = @(Get-ChildItem -Path $d2 -Filter '*.log*')
$newText = if ($newLog.Count) { Get-Content $newLog[0].FullName -Raw } else { '' }
Check ($newText -match 'taskkill_rc=0') '不同 GUID：新实例执行了 taskkill' ($newText -replace "`r?`n", ' ')
Check ($newText -match 'alive') '不同 GUID：新实例杀掉旧的之后自己仍存活'
$oldAlive = @(Get-Process -Id $oldPid -ErrorAction SilentlyContinue).Count
Check ($oldAlive -eq 0) '不同 GUID：旧实例已结束' "剩 $oldAlive"

# 收尾
Get-Process -Name 'probe-mutex' -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($bad -gt 0) { Write-Host "$bad 项不符" -ForegroundColor Red; exit 1 }
Write-Host '全部通过' -ForegroundColor Green