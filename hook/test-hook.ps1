#Requires -Version 5.1
<#
  编译并运行 Hook 自测探针（假 librustdesk.dll + 探针 + SAS.dll 同目录）
  产物与临时目录都在 hook\out\selftest，不写用户目录。

  用法：
    pwsh test-hook.ps1              # 跑假 DLL 自测（probe2）
    pwsh test-hook.ps1 -Only 5      # 跑真实 librustdesk.dll 自测（需已安装 RustDesk）
#>
[CmdletBinding()]
param(
  [int[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here 'out'
$stage = Join-Path $out 'selftest'

# ---------- 复用 build-hook.ps1 的工具链探测 ----------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "找不到 vswhere" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe') } |
        Sort-Object Name -Descending | Select-Object -First 1
$cl = Join-Path $msvc.FullName 'bin\Hostx64\x64\cl.exe'
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
$sdkVer = Get-ChildItem (Join-Path $sdkRoot 'Include') -Directory |
          Where-Object { Test-Path (Join-Path $_.FullName 'um\windows.h') } |
          Sort-Object Name -Descending | Select-Object -First 1

$env:PATH = "$($msvc.FullName)\bin\Hostx64\x64;$env:PATH"
$env:INCLUDE = (@(
  (Join-Path $msvc.FullName 'include'),
  (Join-Path $sdkVer.FullName 'ucrt'),
  (Join-Path $sdkVer.FullName 'um'),
  (Join-Path $sdkVer.FullName 'shared')
) -join ';')
$env:LIB = (@(
  (Join-Path $msvc.FullName 'lib\x64'),
  (Join-Path $sdkRoot "Lib\$($sdkVer.Name)\ucrt\x64"),
  (Join-Path $sdkRoot "Lib\$($sdkVer.Name)\um\x64")
) -join ';')

$sas = Join-Path $out 'SAS.dll'
if (-not (Test-Path $sas)) { throw "缺少 $sas，先跑 build-hook.ps1" }

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item $sas $stage
New-Item -ItemType File -Path (Join-Path $stage 'portable') -Force | Out-Null

# 假 librustdesk.dll
& $cl /nologo /utf-8 /LD /O1 /MT (Join-Path $here 'test_fake_lib.c') "/Fo$stage\" `/Fe:"$stage\librustdesk.dll" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "test_fake_lib 编译失败" }

$probes = @(2)
if ($Only.Count -gt 0) { $probes = $Only }

$failed = @()
foreach ($i in $probes) {
    $src = Join-Path $here "test_probe$i.c"
    if (-not (Test-Path $src)) { Write-Host "跳过 probe$i（无源码）" -ForegroundColor Yellow; continue }

    # probe5 用真实 librustdesk.dll：必须放在名为 RustDesk 的目录里，
    # 让 SAS.dll 从同目录被优先加载（否则会用到 System32 的真实 SAS.dll）
    $runDir = $stage
    if ($i -eq 5) {
        $runDir = Join-Path $stage 'RustDesk'
        $real = 'C:\Program Files\RustDesk\librustdesk.dll'
        if (-not (Test-Path $real)) { Write-Host "跳过 probe5（未安装 RustDesk）" -ForegroundColor Yellow; continue }
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        Copy-Item $real $runDir -Force
        Copy-Item $sas   $runDir -Force
        New-Item -ItemType File -Path (Join-Path $runDir 'portable') -Force | Out-Null
        $env:RDLITE_HOOK_LOG = Join-Path $runDir 'hook.log'
        Remove-Item $env:RDLITE_HOOK_LOG -ErrorAction SilentlyContinue
    }

    $exe = Join-Path $stage "probe$i.exe"
    & $cl /nologo /utf-8 /O1 /MT $src "/Fo$stage\" "/Fe:$exe" /link shell32.lib ole32.lib user32.lib | Out-Null
    if ($LASTEXITCODE -ne 0) { $failed += "probe$i 编译"; continue }

    Write-Host "`n===== probe$i =====" -ForegroundColor Cyan
    Push-Location $runDir
    try {
        if ($i -eq 5) { & $exe (Join-Path $runDir 'librustdesk.dll') } else { & $exe }
        if ($LASTEXITCODE -ne 0) { $failed += "probe$i 退出码 $LASTEXITCODE" }
    } finally { Pop-Location }

    if ($i -eq 5 -and (Test-Path $env:RDLITE_HOOK_LOG)) {
        Write-Host '--- hook log ---' -ForegroundColor DarkGray
        Get-Content $env:RDLITE_HOOK_LOG | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
}
$env:RDLITE_HOOK_LOG = $null

if ($failed.Count -gt 0) {
    Write-Host "`n失败: $($failed -join '; ')" -ForegroundColor Red
    exit 1
}
Write-Host "`n全部通过" -ForegroundColor Green