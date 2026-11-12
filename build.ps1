#Requires -Version 5.1
<#
  RustDesk Lite 构建脚本
  1) 把 C:\Program Files\RustDesk 复制成 payload\app 并做精简
  2) 生成内置 ID 服务器 / Key 的 config（payload\cfg\RustDesk2.toml）
  3) 调用 makensis 打成单文件 exe（LZMA 固实压缩）

  用法示例：
    pwsh build.ps1
    pwsh build.ps1 -IdServer 1.2.3.4 -Key xxxx -Mode full
#>
[CmdletBinding()]
param(
  [string]$Source,
  [string]$NsisExe,
  [string]$IdServer,
  [string]$Key,
  [string]$RelayServer,
  [string]$Password,
  [ValidateSet('lite', 'full')][string]$Mode,
  [string]$AppName,
  [string]$OutFile,
  [string]$ExecLevel = 'admin',
  [string]$AppExeRel = 'rustdesk.exe',
  [string]$AppImage = '',
  [string]$AppArgs = '',
  [string]$HookDll = '',
  [int]$TrialDays = -1,
  [switch]$ReusePayload,
  [switch]$SkipCompile,
  [switch]$NoIcon
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------- 读取默认参数 ----------------
# settings.psd1 是仓库里的模板（不含服务器与 Key）；
# settings.local.psd1 是本地私密配置（已 .gitignore），存在时逐项覆盖模板。
$cfg = @{}
$settingsFile = Join-Path $root 'settings.psd1'
if (Test-Path $settingsFile) { $cfg = Import-PowerShellDataFile -Path $settingsFile }
$localFile = Join-Path $root 'settings.local.psd1'
if (Test-Path $localFile) {
  $localCfg = Import-PowerShellDataFile -Path $localFile
  foreach ($k in $localCfg.Keys) { $cfg[$k] = $localCfg[$k] }
}

$scriptBound = $PSBoundParameters
function Pick($name, $default) {
  if ($scriptBound.ContainsKey($name) -and $scriptBound[$name]) { return $scriptBound[$name] }
  if ($cfg.ContainsKey($name) -and $cfg[$name]) { return $cfg[$name] }
  return $default
}

$Source     = Pick 'Source'     'C:\Program Files\RustDesk'
$NsisExe    = Pick 'NsisExe'    (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe')
$IdServer   = Pick 'IdServer'   ''
$Key        = Pick 'Key'        ''
$RelayServer= Pick 'RelayServer' ''
$Password   = Pick 'Password'   ''
$Mode       = Pick 'Mode'       'lite'
$AppName    = Pick 'AppName'    'RustDesk Lite'
$HookDll    = Pick 'HookDll'    (Join-Path $root 'hook\out\SAS.dll')

# 有效期：0 或负数表示不限制；settings 里可写 TrialDays = 30
if ($TrialDays -lt 0) {
  if ($cfg.ContainsKey('TrialDays') -and "$($cfg['TrialDays'])" -ne '') { $TrialDays = [int]$cfg['TrialDays'] }
  else { $TrialDays = 30 }
}

if (-not $IdServer) { throw '未配置 IdServer：请在 settings.local.psd1 里填写（参考 settings.psd1 模板），或传 -IdServer' }
if (-not $Key)      { throw '未配置 Key：请在 settings.local.psd1 里填写（参考 settings.psd1 模板），或传 -Key' }
if (-not (Test-Path $Source)) { throw "源目录不存在: $Source（需要先安装官方 RustDesk）" }
if (-not (Test-Path $NsisExe)) { throw "makensis 不存在: $NsisExe（安装 NSIS 3.x 或改 settings.local.psd1 的 NsisExe）" }

$payload = Join-Path $root 'payload'
$appDir  = Join-Path $payload 'app'
$cfgDir  = Join-Path $payload 'cfg'
$distDir = Join-Path $root 'dist'
if (-not $OutFile) { $OutFile = (Join-Path $distDir (($AppName -replace '\s', '') + '.exe')) }
elseif (-not [System.IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path $root $OutFile }

# ---------------- 1. 复制载荷 ----------------
$reuse = $ReusePayload -and (Test-Path (Join-Path $appDir 'rustdesk.exe'))
if ($reuse) {
  Write-Host "[1/4] 复用已有 payload（跳过复制/精简）" -ForegroundColor Cyan
  $after = (Get-ChildItem $appDir -Recurse -File -Force | Measure-Object Length -Sum).Sum
} else {
Write-Host "[1/4] 复制 RustDesk 文件 ..." -ForegroundColor Cyan
if (Test-Path $payload) { Remove-Item $payload -Recurse -Force }
New-Item -ItemType Directory -Path $appDir, $cfgDir -Force | Out-Null
robocopy $Source $appDir /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy 复制失败，退出码 $LASTEXITCODE" }

# ---------------- 2. 精简 ----------------
Write-Host "[2/4] 精简 ($Mode) ..." -ForegroundColor Cyan
$before = (Get-ChildItem $appDir -Recurse -File -Force | Measure-Object Length -Sum).Sum
$removed = @()

# 全模式都去掉：安装器残留
$always = @('Uninstall RustDesk.lnk')
# 精简模式额外去掉：虚拟显示器驱动包、打印机驱动包、许可声明、更新缓存
$lite   = @('usbmmidd_v2', 'drivers', 'data\flutter_assets\NOTICES.Z')

$targets = @()
$targets += $always
if ($Mode -eq 'lite') { $targets += $lite }

foreach ($rel in $targets) {
  $full = Join-Path $appDir $rel
  if (Test-Path $full) {
    $size = 0
    $item = Get-Item $full -Force
    if ($item.PSIsContainer) { $size = (Get-ChildItem $full -Recurse -File -Force | Measure-Object Length -Sum).Sum }
    else { $size = $item.Length }
    Remove-Item $full -Recurse -Force
    $removed += [pscustomobject]@{ 名称 = $rel; 节省 = ('{0:N0} KB' -f ($size / 1KB)) }
  }
}

$after = (Get-ChildItem $appDir -Recurse -File -Force | Measure-Object Length -Sum).Sum
$removed | Format-Table -AutoSize | Out-String | Write-Host
Write-Host ("    载荷体积: {0:N1} MB -> {1:N1} MB" -f ($before / 1MB), ($after / 1MB)) -ForegroundColor DarkGray
}

# ---------------- 2.5 注入劫持壳 ----------------
if (-not (Test-Path $HookDll)) {
  throw "缺少 Hook DLL: $HookDll`n先编译：$root\hook\build-hook.ps1（需要 Visual Studio 的 C++ 桌面开发工具集）"
}
Copy-Item $HookDll (Join-Path $appDir 'SAS.dll') -Force
Write-Host ("    劫持壳已注入: SAS.dll ({0:N1} KB)" -f ((Get-Item $HookDll).Length / 1KB)) -ForegroundColor DarkGray

# no-op 小程序：Hook 用它顶替 RustDesk 每帧执行的 tasklist | findstr
$nopSrc = Join-Path (Split-Path $HookDll -Parent) 'rdnop.exe'
if (Test-Path $nopSrc) {
  Copy-Item $nopSrc (Join-Path $appDir 'rdnop.exe') -Force
  Write-Host ("    no-op 程序: rdnop.exe ({0:N1} KB)" -f ((Get-Item $nopSrc).Length / 1KB)) -ForegroundColor DarkGray
} else {
  Write-Host "    未找到 rdnop.exe，UAC 探测仍会启动 tasklist（可运行 hook\build-hook.ps1 生成）" -ForegroundColor DarkYellow
}

# ---------------- 3. 生成内置服务器配置 ----------------
Write-Host "[3/4] 生成配置 (ID服务器=$IdServer) ..." -ForegroundColor Cyan
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('[options]')
$lines.Add("custom-rendezvous-server = '$IdServer'")
if ($RelayServer) { $lines.Add("relay-server = '$RelayServer'") }
$lines.Add("key = '$Key'")
# 便携模式没有服务，隐藏托盘里会失效的“停止服务”菜单项
$lines.Add("hide-stop-service = 'Y'")
$tomlText = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText((Join-Path $cfgDir 'RustDesk2.toml'), $tomlText, (New-Object System.Text.UTF8Encoding($false)))

# ---------------- 3.5 固定密码（可选） ----------------
# 写在 RustDesk.toml 的 password 字段。RustDesk 支持明文存储（校验时直接比对，
# 见 hbb_common::config::permanent_password::local_permanent_password_storage_matches_plain），
# 客户端后续会按自己的规则（机器 UUID 派生的密钥）把它加密成 "01..." 存储。
$pwdFile = Join-Path $cfgDir 'RustDesk.toml'
if ($Password) {
  if ($Password.Contains("'")) { throw "Password 不能包含单引号（会破坏 TOML 字面量）" }
  $pwdText = "password = '$Password'`r`n"
  [System.IO.File]::WriteAllText($pwdFile, $pwdText, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "    已内置固定密码 -> RustDesk.toml" -ForegroundColor DarkGray
} elseif (Test-Path $pwdFile) {
  Remove-Item $pwdFile -Force    # 不带密码时清掉上一次构建的残留
}

# ---------------- 4. 编译 ----------------
if ($SkipCompile) { Write-Host "[4/4] 已跳过编译" -ForegroundColor Yellow; return }

Write-Host "[4/4] 编译单文件 exe ..." -ForegroundColor Cyan
$nsiPath = Join-Path $root 'nsis\RustDeskLite.nsi'

# .nsi 需要 UTF-8 BOM，否则中文提示会按 ANSI 解析成乱码
$bytes = [System.IO.File]::ReadAllBytes($nsiPath)
if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
  $text = [System.IO.File]::ReadAllText($nsiPath, [System.Text.Encoding]::UTF8)
  [System.IO.File]::WriteAllText($nsiPath, $text, (New-Object System.Text.UTF8Encoding($true)))
}

New-Item -ItemType Directory -Path (Split-Path -Parent $OutFile) -Force | Out-Null

# 图标：优先用 nsis\app.ico（自定义图标，只读取、不修改）；缺失时才从源 exe 提取
$iconSrc = Join-Path $root 'nsis\app.ico'
$iconPath = Join-Path $payload 'app.ico'
$iconOk = $false
if (-not $NoIcon) {
  if (Test-Path $iconSrc) {
    # 规范化：有些导出工具会把 ICONDIRENTRY 的 planes / bpp 写成 0，
    # Windows 有时会因此不显示图标。这里按 DIB 头补正，只改副本。
    $b = [System.IO.File]::ReadAllBytes($iconSrc)
    if ($b.Length -lt 22 -or [BitConverter]::ToUInt16($b, 2) -ne 1) {
      throw "不是有效的 .ico 文件: $iconSrc"
    }
    $n = [BitConverter]::ToUInt16($b, 4)
    $sizes = @()
    for ($i = 0; $i -lt $n; $i++) {
      $e = 6 + $i * 16
      $ofs = [BitConverter]::ToInt32($b, $e + 12)
      $b[$e + 4] = 1; $b[$e + 5] = 0                      # planes = 1
      if ($b[$e + 6] -eq 0 -and $b[$e + 7] -eq 0 -and $ofs + 16 -lt $b.Length) {
        $bc = [BitConverter]::ToUInt16($b, $ofs + 14)     # DIB 的 biBitCount
        $b[$e + 6] = [byte]($bc -band 0xFF)
        $b[$e + 7] = [byte](($bc -shr 8) -band 0xFF)
      }
      if ($b[$e] -eq 0) { $side = 256 } else { $side = $b[$e] }
      $sizes += $side
    }
    [System.IO.File]::WriteAllBytes($iconPath, $b)
    $iconOk = $true
    Write-Host ("    使用自定义图标: nsis\app.ico ({0} KB, {1} 个尺寸: {2})" -f `
      [math]::Round($b.Length / 1KB, 1), $n, (($sizes | ForEach-Object { "${_}x$_" }) -join '/')) -ForegroundColor DarkGray
    $maxSize = ($sizes | Measure-Object -Maximum).Maximum
    if ($maxSize -lt 48) {
      Write-Host ("    提示：图标仅 {0}x{0}，放大显示（大图标视图 / Alt+Tab 缩略）会变模糊；如需清晰大图标请提供 256x256 源图" -f $maxSize) -ForegroundColor DarkYellow
    }
  } else {
    try {
      $ico = [System.Drawing.Icon]::ExtractAssociatedIcon((Join-Path $appDir $AppExeRel))
      $fs = [System.IO.File]::Create($iconPath)
      $ico.Save($fs)
      $fs.Close()
      $iconOk = $true
      Write-Host "    未找到 nsis\app.ico，改用源程序图标" -ForegroundColor DarkYellow
    } catch {
      Write-Host "    图标获取失败，使用 NSIS 默认图标" -ForegroundColor DarkYellow
    }
  }
}

$defs = @(
  '/V2',
  "/DAPP_NAME=$AppName",
  "/DOUT_FILE=$OutFile",
  "/DPAYLOAD_DIR=$payload",
  "/DEXEC_LEVEL=$ExecLevel",
  "/DAPP_EXE_REL=$AppExeRel",
  "/DAPP_ARGS=$AppArgs"
)
if (-not $AppImage) { $AppImage = $AppExeRel }
$defs += "/DAPP_IMAGE=$AppImage"
if ($iconOk) { $defs += "/DAPP_ICON=$iconPath" }
if ($Password) { $defs += '/DHAS_PW' }
$defs += "/DTRIAL_DAYS=$TrialDays"

# 有效期：编译日期与到期日都在这里算好，作为常量写死进 exe。
# 不用 ${__DATE__}（格式随系统区域设置变化），也不用运行期推算。
if ($TrialDays -gt 0) {
  $buildDate  = (Get-Date).Date
  $expireDate = $buildDate.AddDays($TrialDays)
  $defs += "/DBUILD_DATE=$($buildDate.ToString('yyyyMMdd'))"
  $defs += "/DBUILD_DATE_TEXT=$($buildDate.ToString('yyyy-MM-dd'))"
  $defs += "/DEXPIRE_DATE=$($expireDate.ToString('yyyyMMdd'))"
  $defs += "/DEXPIRE_DATE_TEXT=$($expireDate.ToString('yyyy-MM-dd'))"
  Write-Host ("    有效期: {0} 编译，{1} 到期（{2} 天）" -f `
    $buildDate.ToString('yyyy-MM-dd'), $expireDate.ToString('yyyy-MM-dd'), $TrialDays) -ForegroundColor DarkGray
} else {
  Write-Host "    有效期: 不限制" -ForegroundColor DarkGray
}

& $NsisExe @defs $nsiPath
if ($LASTEXITCODE -ne 0) { throw "makensis 编译失败，退出码 $LASTEXITCODE" }
if (-not (Test-Path $OutFile)) { throw "未生成输出文件: $OutFile" }

$outItem = Get-Item $OutFile
$hash = (Get-FileHash $OutFile -Algorithm SHA256).Hash
Write-Host ''
Write-Host "已完成 -> $($outItem.FullName)" -ForegroundColor Green
Write-Host ("  体积: {0:N1} MB（载荷 {1:N1} MB，压缩率 {2:N0}%）" -f ($outItem.Length / 1MB), ($after / 1MB), (100 - $outItem.Length / $after * 100)) -ForegroundColor Green
Write-Host "  SHA256: $hash" -ForegroundColor Green
