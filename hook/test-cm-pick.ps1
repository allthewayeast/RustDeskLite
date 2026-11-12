$ErrorActionPreference = 'Stop'
$here = 'X:\RustDesk\hook'

# 复用 build-hook.ps1 的 VS/SDK 探测
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$msvc = Get-ChildItem (Join-Path $vsPath 'VC\Tools\MSVC') -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe') } |
        Sort-Object Name -Descending | Select-Object -First 1
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

$cl = Join-Path $msvc.FullName 'bin\Hostx64\x64\cl.exe'
$out = Join-Path $here 'out'
New-Item -ItemType Directory -Path $out -Force | Out-Null

& $cl /nologo /utf-8 /O1 (Join-Path $here 'test-cm-pick.c') "/Fo$out\" "/Fe:$out\test-cm-pick.exe"
if ($LASTEXITCODE -ne 0) { throw "compile failed" }

Write-Host "`n--- run ---" -ForegroundColor Cyan
& "$out\test-cm-pick.exe"
"exit=$LASTEXITCODE"