#Requires -Version 5.1
<#
  验证有效期逻辑（用极小载荷，几秒出结果）

  重点验证「到期日是编译期常量」这条主路径：
    1) 编译产物的版本资源里确实写着编译时间与到期日（写死进 exe，可核对）
    2) 未到期放行、到期日当天放行、过期拒绝
    3) 兜底路径（未传 EXPIRE_DATE 时的日期换算）与 .NET 一致

  用法：pwsh nsis\test-trial.ps1 [-NsisExe <path>]
#>
[CmdletBinding()]
param([string]$NsisExe)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $NsisExe) { $NsisExe = 'D:\App\开发工具\VNISEdit\NSIS\3.10.3.0.x64\makensis.exe' }
if (-not (Test-Path $NsisExe)) { throw "makensis 不存在: $NsisExe" }

$work = Join-Path $here '_trial'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work -Force | Out-Null

$bad = 0
function Check([bool]$ok, [string]$label, [string]$detail = '') {
  if (-not $ok) { $script:bad++ }
  $color = if ($ok) { 'DarkGray' } else { 'Red' }
  Write-Host ("   {0} {1} {2}" -f $(if ($ok) { 'OK  ' } else { 'FAIL' }), $label, $detail) -ForegroundColor $color
}

# =====================================================================
# 1. 编译期常量：到期日与编译日期必须烧进 exe（版本资源可核对）
# =====================================================================
Write-Host "1) 编译期常量写入 exe" -ForegroundColor Cyan

$build = (Get-Date).Date
$expire = $build.AddDays(30)
$nsi = @'
Unicode true
OutFile "OUT_EXE"
SilentInstall silent
RequestExecutionLevel user
!include "LogicLib.nsh"
!include "..\trial.nsh"
VIProductVersion "1.0.0.0"
VIAddVersionKey /LANG=2052 "ProductName"    "TRIAL_PROBE"
VIAddVersionKey /LANG=2052 "FileVersion"    "1.0.0.0"
VIAddVersionKey /LANG=2052 "FileDescription" "expiry probe"
VIAddVersionKey /LANG=2052 "Comments" "built ${BUILD_DATE_TEXT} expire ${EXPIRE_DATE} trial ${TRIAL_DAYS}"
Section
  Call CheckTrial
  FileOpen $9 "OUT_TXT" w
  FileWrite $9 "DaysLeft=$DaysLeft$\r$\n"
  FileClose $9
SectionEnd
'@

$exe = Join-Path $work 'v.exe'
$txt = Join-Path $work 'v.txt'
$src = Join-Path $work 'v.nsi'
$script = $nsi.Replace('OUT_EXE', $exe.Replace('\','\\')).Replace('OUT_TXT', $txt.Replace('\','\\'))
[IO.File]::WriteAllText($src, $script, (New-Object Text.UTF8Encoding($true)))

& $NsisExe /V1 "/DTRIAL_DAYS=30" "/DBUILD_DATE=$($build.ToString('yyyyMMdd'))" "/DEXPIRE_DATE=$($expire.ToString('yyyyMMdd'))" $src 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makensis 编译失败' }

$bytes = [IO.File]::ReadAllBytes($exe)
$u16 = [Text.Encoding]::Unicode
$all = $u16.GetString($bytes)
Check ($all.Contains($expire.ToString('yyyyMMdd'))) "到期日常量在 exe 内" "(EXPIRE_DATE=$($expire.ToString('yyyyMMdd')))"
Check ($all.Contains($build.ToString('yyyy-MM-dd'))) "编译日期文本在 exe 内" "(BUILD_DATE_TEXT=$($build.ToString('yyyy-MM-dd')))"

$vi = (Get-Item $exe).VersionInfo
Check ($vi.Comments -like "*expire $($expire.ToString('yyyyMMdd'))*") "版本资源注释可读" "($($vi.Comments))"

# =====================================================================
# 2. 到期判定（构造 N 天前编译的包，看今天是否放行）
# =====================================================================
Write-Host "`n2) 到期判定（到期日 = 编译日 + 30 天）" -ForegroundColor Cyan

$cases = @(
  @{ offset = 0;   expect = 'run'   },  # 今天编译，还剩 30 天
  @{ offset = 29;  expect = 'run'   },  # 剩 1 天
  @{ offset = 30;  expect = 'run'   },  # 到期日当天，仍可运行
  @{ offset = 31;  expect = 'block' },  # 已过期 1 天
  @{ offset = 365; expect = 'block' },
  @{ offset = -1;  expect = 'block' }   # 编译日期在未来 = 系统时间被回拨
)
foreach ($c in $cases) {
  $b = $build.AddDays(-$c.offset)
  $e = $b.AddDays(30)
  $exe = Join-Path $work "t$($c.offset).exe"
  $txt = Join-Path $work "t$($c.offset).txt"
  $src = Join-Path $work "t$($c.offset).nsi"
  $script = $nsi.Replace('OUT_EXE', $exe.Replace('\','\\')).Replace('OUT_TXT', $txt.Replace('\','\\'))
  [IO.File]::WriteAllText($src, $script, (New-Object Text.UTF8Encoding($true)))

  & $NsisExe /V1 "/DTRIAL_DAYS=30" "/DBUILD_DATE=$($b.ToString('yyyyMMdd'))" "/DEXPIRE_DATE=$($e.ToString('yyyyMMdd'))" $src 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "makensis 失败 offset=$($c.offset)" }

  # 过期时会弹 MessageBox 阻塞，静默模式也不跳过 —— 用超时判断是否被拦下
  $p = Start-Process -FilePath $exe -PassThru
  $done = $p.WaitForExit(3000)
  if (-not $done) { $p.Kill(); $p.WaitForExit() }
  Start-Sleep -Milliseconds 150

  $actual = if (Test-Path $txt) { 'run' } else { 'block' }
  Check ($actual -eq $c.expect) "编译于 $($b.ToString('yyyy-MM-dd'))" "期望 $($c.expect)，实际 $actual"
}

# =====================================================================
# 3. 兜底路径：没传 EXPIRE_DATE 时的日期换算
# =====================================================================
Write-Host "`n3) 兜底路径 DateToDays 与 .NET 对比" -ForegroundColor Cyan

$epoch = [datetime]'1970-01-01'
$dates = @('19700101','19700228','19700301','19991231','20000101','20000229',
           '20240229','20260228','20260301','20261231','20270101','21000229' -replace '21000229','21000228')
$probe = @'
Unicode true
OutFile "OUT_EXE"
SilentInstall silent
RequestExecutionLevel user
!include "LogicLib.nsh"
!include "..\trial.nsh"
Section
  StrCpy $R0 "PROBE_DATE"
  Call DateToDays
  FileOpen $9 "OUT_TXT" w
  FileWrite $9 "days=$R1$\r$\n"
  FileClose $9
SectionEnd
'@
foreach ($d in ($dates | Select-Object -Unique)) {
  $exe = Join-Path $work "d$d.exe"
  $txt = Join-Path $work "d$d.txt"
  $src = Join-Path $work "d$d.nsi"
  $script = $probe.Replace('OUT_EXE', $exe.Replace('\','\\')).Replace('OUT_TXT', $txt.Replace('\','\\')).Replace('PROBE_DATE', $d)
  [IO.File]::WriteAllText($src, $script, (New-Object Text.UTF8Encoding($true)))
  & $NsisExe /V1 $src 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "makensis 失败 $d" }
  & $exe
  Start-Sleep -Milliseconds 120

  $got = [int](Select-String -Path $txt -Pattern 'days=(-?\d+)').Matches[0].Groups[1].Value
  $expect = ([datetime]::new([int]$d.Substring(0,4), [int]$d.Substring(4,2), [int]$d.Substring(6,2)) - $epoch).Days
  Check ($got -eq $expect) "$d" "nsis=$got net=$expect"
}

Write-Host ''
if ($bad -gt 0) { Write-Host "$bad 项不符" -ForegroundColor Red; exit 1 }
Write-Host '全部通过' -ForegroundColor Green