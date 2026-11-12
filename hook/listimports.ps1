# 列出 PE 文件导入的 DLL 名称（只读，用于核对可劫持的 DLL）
param([Parameter(Mandatory=$true)][string]$Path)
$b = [IO.File]::ReadAllBytes($Path)
$e = [BitConverter]::ToInt32($b, 0x3C)
$numSec = [BitConverter]::ToUInt16($b, $e + 6)
$optSize = [BitConverter]::ToUInt16($b, $e + 20)
$opt = $e + 24
$pe32plus = ([BitConverter]::ToUInt16($b, $opt) -eq 0x20b)
$impRva = [BitConverter]::ToInt32($b, $opt + $(if ($pe32plus) { 112 } else { 96 }) + 8)
$sec = $opt + $optSize

function RvaToOff([int]$rva) {
    for ($i = 0; $i -lt $numSec; $i++) {
        $o = $sec + $i * 40
        $vs = [BitConverter]::ToInt32($b, $o + 8)
        $va = [BitConverter]::ToInt32($b, $o + 12)
        $raw = [BitConverter]::ToInt32($b, $o + 20)
        if ($rva -ge $va -and $rva -lt ($va + $vs)) { return $raw + ($rva - $va) }
    }
    return -1
}

$off = RvaToOff $impRva
if ($off -lt 0) { Write-Output "(no import table)"; return }
while ($off -gt 0) {
    $nameRva = [BitConverter]::ToInt32($b, $off + 12)
    if ($nameRva -eq 0) { break }
    $n = RvaToOff $nameRva
    $s = ''
    while ($b[$n] -ne 0) { $s += [char]$b[$n]; $n++ }
    Write-Output $s
    $off += 20
}