; ============================================================================
;  正式版运行状态的持久化（交接给后续实例）
;  ---------------------------------------------------------------------------
;  为什么要落盘：新版本接管时会先 kill 掉旧实例，旧实例的清理代码根本来不及跑，
;  它记在内存里的 WasSvc / WasApp 就丢了。清理时就会"看不到原本在跑"，
;  于是退出后不去恢复正式版的服务/托盘 —— 用户会以为正式版被弄坏了。
;
;  所以把状态写进 %TEMP%\RustDeskLite\state.ini，并且**只由第一个实例写**：
;    First=1  表示服务/托盘已被本工具停掉，退出时由继承了这份状态的实例负责恢复
;    First=0  表示没动过正式版，退出时什么都不用恢复
;  后续实例（新版本接管）读到这份文件就直接继承，不再重新探测 ——
;  此刻正式版已经被停掉了，重新探测只会得到"没在跑"，就把原始状态弄丢了。
;
;  为什么不用 %LOCALAPPDATA%：本包的卖点是退出后不留痕迹，在用户配置目录下
;  常驻一个目录（哪怕只有一个 ini）与这个卖点自相矛盾。%TEMP%\RustDeskLite
;  是独立子目录，既不会被解压目录的 rmdir 误删，退出时又能整个删干净。
;
;  为什么不直接放进解压目录 $TEMP\RustDesk：
;    1) 那个目录在拿到锁后第一件事就是 rmdir —— 状态文件会在
;       "新版本杀掉旧实例、正要去读它继承"的那一刻被自己删掉
;       （确实可以在删之前先读，但只要顺序一改就会静默失效，太脆）；
;    2) 更关键：解压目录被占用时会走兜底路径改名成 $TEMP\RustDesk-<uniq>，
;       路径不固定，新实例根本不知道去哪个目录读。
;  独立固定路径同时避开了这两点。
;
;  引用方必须提供这些变量：
;    $StateDir                       （本文件的 InitState 会设置）
;    $WasSvc / $WasApp               本次探测结果（WriteState 用）
;    $PrevSvc / $PrevApp / $PrevAlive 继承结果（ReadState 用）
;    $Tmp1 / $Tmp2
; ============================================================================

; 设置状态目录（在 .onInit 里最先调用）
Function InitState
  ; 独立于解压目录，见文件头说明
  StrCpy $StateDir "$TEMP\RustDeskLite"
FunctionEnd

; 读出已有状态到 $PrevSvc / $PrevApp / $PrevAlive
Function ReadState
  StrCpy $PrevSvc 0
  StrCpy $PrevApp 0
  StrCpy $PrevAlive 0
  ClearErrors
  ReadINIStr $Tmp1 "$StateDir\state.ini" "state" "First"
  ${If} ${Errors}
    Return                 ; 没有状态文件：首次运行，自己去探测
  ${EndIf}

  ; 只要有状态文件就继承，不再重新探测。理由是两种情形都必须继承：
  ;   1) 写状态的实例还活着（不同编译版本在跑，互斥互相看不见）→ 正式版已被它停掉；
  ;   2) 它已经被我们 kill 掉 → 清理代码没跑，恢复的责任正好转给我们。
  ; 这两种情形下"正式版现在没在跑"都**不代表**它原本没在跑，
  ; 重新探测只会把原始状态覆盖成 0，退出后就不恢复了。

  ; 唯一的例外是状态文件来自上一次开机（实例被强杀后没清理，又重启了机器）。
  ; GetTickCount 是"开机后的毫秒数"，重启会归零变小 —— 借此判断跨了开机。
  ClearErrors
  ReadINIStr $Tmp2 "$StateDir\state.ini" "state" "Ticks"
  ${If} ${Errors}
    StrCpy $Tmp2 0
  ${EndIf}
  System::Call 'kernel32::GetTickCount() i .r1'
  ${If} $1 < $Tmp2
    Delete "$StateDir\state.ini"
    RMDir "$StateDir"
    Return                 ; 跨开机 → 视为陈旧，丢弃后重新探测
  ${EndIf}

  StrCpy $PrevAlive 1

  ReadINIStr $Tmp1 "$StateDir\state.ini" "state" "HadSvc"
  StrCpy $PrevSvc $Tmp1
  ReadINIStr $Tmp1 "$StateDir\state.ini" "state" "HadApp"
  StrCpy $PrevApp $Tmp1
FunctionEnd

; 写入状态（$WasSvc / $WasApp 为本次探测结果）
Function WriteState
  CreateDirectory $StateDir
  WriteINIStr "$StateDir\state.ini" "state" "First"    "1"
  WriteINIStr "$StateDir\state.ini" "state" "HadSvc"   "$WasSvc"
  WriteINIStr "$StateDir\state.ini" "state" "HadApp"   "$WasApp"
  WriteINIStr "$StateDir\state.ini" "state" "Stamp"    "${BUILD_DATE_TEXT}"
  System::Call 'kernel32::GetCurrentProcessId() i .r1'
  WriteINIStr "$StateDir\state.ini" "state" "OwnerPid" "$1"
  System::Call 'kernel32::GetTickCount() i .r1'
  WriteINIStr "$StateDir\state.ini" "state" "Ticks"    "$1"
FunctionEnd

; 清理：自己退出前删掉状态（谁恢复谁负责）。
; 整个目录一起删 —— 状态文件只在运行期间有意义，实例全退后不该留下任何东西。
Function ClearState
  Delete "$StateDir\state.ini"
  RMDir "$StateDir"          ; 目录空了才删得掉（还有别的实例在用时失败，无害）
FunctionEnd