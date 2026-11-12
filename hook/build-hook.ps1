#Requires -Version 5.1
<#
  编译便携化 Hook DLL（SAS.dll）
  需要：Visual Studio / Build Tools（含 "使用 C++ 的桌面开发"）
  产物：默认 X:\RustDesk\hook\out\SAS.dll

  说明：不走 vcvars64.bat（它会调用 reg.exe，受限环境容易被拦），
        这里直接探测 MSVC 与 Windows SDK 路径后设置 INCLUDE/LIB/PATH。

  用法：
    pwsh build-hook.ps1
    pwsh build-hook.ps1 -OutDir D:\somewhere
#>
[CmdletBinding()]
param(
  [string]$OutDir = 'X:\RustDesk\hook\out'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = Join-Path $here 'out' }

# ---------- 1. 定位 VS ----------
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "找不到 vswhere，请确认已安装 Visual Studio / Build Tools" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw "未找到含 C++ 工具集的 VS 安装（需要安装 C++ 桌面开发工作负载）" }
Write-Host "VS: $vsPath" -ForegroundColor Green

# ---------- 2. 定位 MSVC ----------
$msvcRoot = Join-Path $vsPath 'VC\Tools\MSVC'
if (-not (Test-Path $msvcRoot)) { throw "找不到 $msvcRoot" }
$msvc = Get-ChildItem $msvcRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe') } |
        Sort-Object Name -Descending | Select-Object -First 1
if (-not $msvc) { throw "未找到 x64 的 cl.exe（请安装 x64 生成工具）" }
$cl = Join-Path $msvc.FullName 'bin\Hostx64\x64\cl.exe'
Write-Host "MSVC: $($msvc.Name)" -ForegroundColor Green

# ---------- 3. 定位 Windows SDK ----------
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10'
if (-not (Test-Path $sdkRoot)) { throw "找不到 Windows SDK: $sdkRoot" }
$sdkVer = Get-ChildItem (Join-Path $sdkRoot 'Include') -Directory |
          Where-Object { Test-Path (Join-Path $_.FullName 'um\windows.h') } |
          Sort-Object Name -Descending | Select-Object -First 1
if (-not $sdkVer) { throw "Windows SDK 不完整（缺少 um\windows.h）" }
Write-Host "SDK:  $($sdkVer.Name)" -ForegroundColor Green

# ---------- 4. 环境 ----------
$env:PATH = "$($msvc.FullName)\bin\Hostx64\x64;$env:PATH"
$env:INCLUDE = (@(
  (Join-Path $msvc.FullName 'include'),
  (Join-Path $sdkVer.FullName 'ucrt'),
  (Join-Path $sdkVer.FullName 'um'),
  (Join-Path $sdkVer.FullName 'shared'),
  (Join-Path $sdkVer.FullName 'winrt')
) -join ';')
$env:LIB = (@(
  (Join-Path $msvc.FullName 'lib\x64'),
  (Join-Path $sdkRoot "Lib\$($sdkVer.Name)\ucrt\x64"),
  (Join-Path $sdkRoot "Lib\$($sdkVer.Name)\um\x64")
) -join ';')

# ---------- 5. 编译 ----------
$minhookInc = Join-Path $here 'minhook\include'
$minhookSrc = Join-Path $here 'minhook\src'
if (-not (Test-Path (Join-Path $minhookInc 'MinHook.h'))) { throw "缺少 MinHook 源码: $minhookInc" }

$sources = @(
  (Join-Path $here 'sas_proxy.c'),
  (Join-Path $minhookSrc 'buffer.c'),
  (Join-Path $minhookSrc 'hook.c'),
  (Join-Path $minhookSrc 'trampoline.c'),
  (Join-Path $minhookSrc 'hde\hde64.c')
)
foreach ($s in $sources) { if (-not (Test-Path $s)) { throw "缺少源文件: $s" } }

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$dll = Join-Path $OutDir 'SAS.dll'
Write-Host "编译中 ..." -ForegroundColor Cyan

& $cl /nologo /utf-8 /LD /O2 /MT /W3 "/I$minhookInc" @sources "/Fo$OutDir\" "/Fe:$dll" /link "/DEF:$(Join-Path $here 'sas.def')" /MACHINE:X64
if ($LASTEXITCODE -ne 0) { throw "编译失败（退出码 $LASTEXITCODE）" }
if (-not (Test-Path $dll)) { throw "未生成 $dll" }

Write-Host ("完成: {0}  ({1:N1} KB)" -f $dll, ((Get-Item $dll).Length / 1KB)) -ForegroundColor Green

# ---------- 6. 编译 no-op 小程序（替代每帧执行的 tasklist | findstr） ----------
$nop = Join-Path $OutDir 'rdnop.exe'
& $cl /nologo /utf-8 /c /O1 /GS- (Join-Path $here 'nop.c') "/Fo$OutDir\" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "rdnop.exe 编译失败" }
$link = Join-Path (Split-Path $cl -Parent) 'link.exe'
& $link /nologo /SUBSYSTEM:WINDOWS /ENTRY:nopEntry /NODEFAULTLIB "$OutDir\nop.obj" kernel32.lib "/OUT:$nop" | Out-Null
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $nop)) { throw "rdnop.exe 链接失败" }
Write-Host ("完成: {0}  ({1:N1} KB)" -f $nop, ((Get-Item $nop).Length / 1KB)) -ForegroundColor Green
Write-Host "自测：把 SAS.dll 放在 rustdesk.exe 同目录，同目录建一个名为 portable 的空文件，运行后配置应出现在 <该目录>\config" -ForegroundColor Cyan
