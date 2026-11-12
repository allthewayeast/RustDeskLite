# 在远端被控机的 Session 2（交互式桌面）里执行任意 PowerShell 脚本
#
# 为什么需要这个：
#   RustDesk 的 TCP 隧道/SSH 登录落在 Session 0（services），而 GUI 窗口在
#   Session 2（console）。跨 session 调 EnumWindows 只能看到 Session 0 的窗口，
#   拿不到 CM 窗口和主窗口的真实状态。
#
# 解决办法（和 RustDesk 自己的平台层同思路）：
#   用「计划任务 + LogonType=InteractiveToken + RunLevel=HighestAvailable」
#   把进程塞进用户已登录的那个交互式 session。对应上游
#   src/platform/windows.cc:250 LaunchProcessWin() 的做法。
#
# 踩过的坑（都已在下面处理）：
#   1. schtasks 内联传 /tr 带引号的复杂命令行，经 SSH 会被剥掉引号 →
#      改成上传 XML 文件，用 /xml 创建。
#   2. /it（交互式）单独用时不可靠；XML 里写 LogonType=InteractiveToken 才稳。
#   3. powershell.exe(5.1) 的 Get-Process 没有 CommandLine 属性、CIM 也可能被拦 →
#      改用 pwsh 7（远端在 C:\Program Files\PowerShell\7\pwsh.exe）。
#   4. 任务报"成功"但输出文件读不到，通常只是读得太早 → 下面用轮询等文件出现。
#
# 用法：
#   .\rd-remote.ps1 -ScriptFile .\some-script.ps1
#   .\rd-remote.ps1 -ScriptFile .\some-script.ps1 -WaitSeconds 30
#   .\rd-remote.ps1 -ScriptFile .\some-script.ps1 -RemoteHost 127.0.0.1 -RemotePort 10022 `
#                   -RemoteUser 'MYPC\Administrator' -AskPass .\askpass.bat
#
# 前置：远端已装 pwsh 7；本机要有 SSH 密码助手（一个只 echo 密码的 .bat，
#       例如 askpass.bat，已在 .gitignore 里，不会被提交）。
param(
  [Parameter(Mandatory=$true)][string]$ScriptFile,
  [string]$RemoteHost = '127.0.0.1',
  [int]$RemotePort    = 10022,
  [string]$RemoteDir  = 'C:\Windows\Temp\rdlite',
  [string]$TaskName   = 'RDLiteRun',
  # 计划任务要求 UserId 是系统真实用户名；用 `whoami` 在远端确认，域名大小写敏感
  [string]$RemoteUser = '',
  # SSH 登录名（与上面的 RemoteUser 可以不同）
  [string]$SshUser    = 'Administrator',
  [string]$PwshPath   = 'C:\Program Files\PowerShell\7\pwsh.exe',
  [string]$AskPass    = (Join-Path $PSScriptRoot 'askpass.bat'),
  [int]$WaitSeconds   = 20,
  [switch]$KeepTask
)

$ErrorActionPreference = 'Stop'

if (-not $RemoteUser) {
  throw "缺少 -RemoteUser。在被控机上执行 whoami 取得形如 HOST\Administrator 的值后传入。"
}
if (-not (Test-Path $AskPass)) {
  throw "找不到 SSH 密码助手：$AskPass（一个只 echo 密码的 .bat）"
}

$sshCommon = @('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',
               '-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no',
               '-o','ConnectTimeout=12')
$sshArgs = $sshCommon + @('-p', "$RemotePort", "$SshUser@$RemoteHost")
$scpArgs = $sshCommon + @('-P', "$RemotePort")
$scpTarget = "$SshUser@${RemoteHost}"

$env:SSH_ASKPASS         = (Resolve-Path $AskPass).Path
$env:SSH_ASKPASS_REQUIRE = 'force'
$env:DISPLAY             = ':0'

function Invoke-Remote([string]$cmd) {
  $r = & ssh @sshArgs $cmd 2>&1
  return @($r | Where-Object { $_ -notmatch '^Warning: Permanently added' })
}

# 1) 远端目录
Invoke-Remote "if not exist $RemoteDir mkdir $RemoteDir" | Out-Null

# 2) 上传 payload + runner
$localRunner = Join-Path $PSScriptRoot 'rdlite-runner.ps1'
& scp @scpArgs $ScriptFile  "${scpTarget}:${RemoteDir}/payload.ps1" 2>&1 | Out-Null
& scp @scpArgs $localRunner "${scpTarget}:${RemoteDir}/runner.ps1"  2>&1 | Out-Null

# 3) 渲染任务 XML（UTF-16 带 BOM，schtasks 需要）
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>RustDesk Lite Session2 runner</Description></RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>$RemoteUser</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled><Hidden>false</Hidden><RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$PwshPath</Command>
      <Arguments>-NoProfile -NoLogo -ExecutionPolicy Bypass -File $RemoteDir\runner.ps1</Arguments>
    </Exec>
  </Actions>
</Task>
"@
$tmpXml = Join-Path $env:TEMP 'rdlite-task-rendered.xml'
# 必须写真正的 UTF-16(带 BOM)：XML 头声明 encoding="UTF-16"，
# 若实际写成 UTF-8 BOM，schtasks 会把 BOM 当内容，报"(1,2) 不正确的文档语法"。
[System.IO.File]::WriteAllText($tmpXml, $xml, [System.Text.UnicodeEncoding]::new($false, $true))
& scp @scpArgs $tmpXml "${scpTarget}:${RemoteDir}/task.xml" 2>&1 | Out-Null

# 4) 建任务 + 清旧输出 + 运行
Invoke-Remote "schtasks /create /tn $TaskName /xml ${RemoteDir}\task.xml /f" | Out-Null
Invoke-Remote "del ${RemoteDir}\out.txt" | Out-Null
Invoke-Remote "schtasks /run /tn $TaskName" | Out-Null

# 5) 轮询等输出文件出现
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$got = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 800
  $exists = Invoke-Remote "if exist ${RemoteDir}\out.txt echo YES"
  if (($exists -join '') -match 'YES') { $got = $true; break }
}
Start-Sleep -Milliseconds 300

if ($got) {
  Invoke-Remote "type ${RemoteDir}\out.txt"
} else {
  "TIMEOUT: 输出文件未生成。任务状态："
  Invoke-Remote "schtasks /query /tn $TaskName /fo LIST /v" | Select-String '上次结果|Last Result|上次运行时间'
}

if (-not $KeepTask) {
  Invoke-Remote "schtasks /delete /tn $TaskName /f" | Out-Null
}