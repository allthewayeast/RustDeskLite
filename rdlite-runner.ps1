# Session 2 通用执行器：由 X:\RustDesk\rd-remote.ps1 投放到远端并调用
# 职责：把 payload.ps1 跑起来，把所有输出（含错误、异常）落到 out.txt
#
# 关键点（实测定下来的）：
#   不要用 "& $Script" 然后在内存里攒 buffer 再写文件 —— 一旦 payload 里
#   调 Add-Type 编译 C#，进程会卡住不返回，输出文件永远不生成。
#   用 "*> $Out" 让 PowerShell 自己把流重定向到文件，进程能正常跑完。
param(
  [string]$Script = 'C:\Windows\Temp\rdlite\payload.ps1',
  [string]$Out    = 'C:\Windows\Temp\rdlite\out.txt'
)

$ErrorActionPreference = 'Continue'

# 先写一行"我启动了"，这样即使后面卡死也能判断卡在哪一步
"runner start=$(Get-Date -Format 'HH:mm:ss') ps=$($PSVersionTable.PSVersion) session=$((Get-Process -Id $PID).SessionId)" |
  Set-Content -Path $Out -Encoding utf8

if (-not (Test-Path $Script)) {
  "PAYLOAD MISSING: $Script" | Add-Content -Path $Out -Encoding utf8
  exit 1
}

try {
  & $Script *>> $Out
} catch {
  "EXCEPTION: $($_.Exception.Message)" | Add-Content -Path $Out -Encoding utf8
}

"runner done=$(Get-Date -Format 'HH:mm:ss') exit=$LASTEXITCODE" | Add-Content -Path $Out -Encoding utf8