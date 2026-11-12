; Unit test for the state hand-off logic (ReadState / WriteState / ClearState).
;
; 为什么需要这个测试：
;   "第一个实例记住正式版运行状态"这件事靠一个落盘的 state.ini 交接。
;   新版本接管时会 kill 掉旧实例，旧实例的清理代码根本来不及跑，
;   所以状态必须能从文件继承；同时还要能识别"上次开机遗留的陈旧状态"。
;   这两个分支都不容易在真机上复现，用编译型探针固化下来。
;
; 运行：nsis\test-state.ps1
; 不触碰任何 RustDesk 进程，只读写 X:\RustDesk\dist\_statetest 下的临时 ini。
Unicode true
!include "LogicLib.nsh"

!ifndef OUT_FILE
  !define OUT_FILE "..\dist\state-test.exe"
!endif
!ifndef LOG
  !define LOG "..\dist\_state-test.txt"
!endif
!ifndef STATE_DIR
  !define STATE_DIR "..\dist\_statetest"
!endif

!define BUILD_DATE_TEXT "TEST"

Name "state-test"
OutFile "${OUT_FILE}"
RequestExecutionLevel user
SilentInstall silent

Var StateDir
Var WasSvc
Var WasApp
Var PrevSvc
Var PrevApp
Var PrevAlive
Var Tmp1
Var Tmp2

; ---- 被测逻辑：直接 include 产品用的同一份实现 ----
; 不要再在这里手抄副本。之前抄了一份，改了 RustDeskLite.nsi 里的 ClearState
; （加 RMDir 删目录）却忘了同步副本，测试就报了两个假 FAIL。
!include "state.nsh"

!macro CheckLabel NAME EXPECTED GOT
  Push $0
  StrCpy $0 "${EXPECTED}"
  ${If} "${GOT}" == "$0"
    FileWrite $9 "[PASS] ${NAME}$\r$\n"
  ${Else}
    FileWrite $9 "[FAIL] ${NAME}  expected=${EXPECTED} got=${GOT}$\r$\n"
  ${EndIf}
  Pop $0
!macroend

Section
  StrCpy $StateDir "${STATE_DIR}"
  Delete "${LOG}"
  FileOpen $9 "${LOG}" w
  FileWrite $9 "=== state hand-off unit test ===$\r$\n"

  ; 0. 产品默认的状态目录必须独立于解压目录 —— 解压目录在拿到锁后立刻被
  ;    rmdir（被占用时还会改名），状态文件放进去就会在"正要读它继承"时被删掉。
  ;    注意这里比的是**完整路径**，不能用前缀判断：
  ;    "$TEMP\RustDeskLite" 的字符串前缀恰好也是 "$TEMP\RustDesk"。
  Call InitState
  Push $0
  Push $1
  StrCpy $0 "$TEMP\RustDeskLite"
  StrCpy $1 "$TEMP\RustDesk"
  ${If} $StateDir == $0
    FileWrite $9 "[PASS] 0 InitState returns TEMP\RustDeskLite$\r$\n"
  ${Else}
    FileWrite $9 "[FAIL] 0 InitState expected=$0 got=$StateDir$\r$\n"
  ${EndIf}
  ${If} $StateDir == $1
    FileWrite $9 "[FAIL] 0 state dir must NOT be the extract dir$\r$\n"
  ${Else}
    FileWrite $9 "[PASS] 0 state dir differs from extract dir$\r$\n"
  ${EndIf}
  Pop $1
  Pop $0
  StrCpy $StateDir "${STATE_DIR}"    ; 后续用例改用测试临时目录

  ; 1. 没有状态文件 = 首次运行，什么都不继承
  Delete "$StateDir\state.ini"
  StrCpy $WasSvc 0
  StrCpy $WasApp 0
  Call ReadState
  !insertmacro CheckLabel "1 no file -> PrevAlive=0" "0" "$PrevAlive"

  ; 2/3. 首个实例记下 1/1，后续实例必须原样继承
  StrCpy $WasSvc 1
  StrCpy $WasApp 1
  Call WriteState
  StrCpy $PrevSvc 9
  StrCpy $PrevApp 9
  StrCpy $PrevAlive 0
  Call ReadState
  !insertmacro CheckLabel "3 inherit PrevAlive=1" "1" "$PrevAlive"
  !insertmacro CheckLabel "3 inherit PrevSvc=1"   "1" "$PrevSvc"
  !insertmacro CheckLabel "3 inherit PrevApp=1"   "1" "$PrevApp"

  ; 4. 原本什么都没跑：也要记 0/0，退出时才不会去"恢复"
  Call ClearState
  StrCpy $WasSvc 0
  StrCpy $WasApp 0
  Call WriteState
  Call ReadState
  !insertmacro CheckLabel "4 zero state PrevAlive=1" "1" "$PrevAlive"
  !insertmacro CheckLabel "4 zero state PrevSvc=0"   "0" "$PrevSvc"

  ; 5. 陈旧状态（来自上一次开机）必须丢弃，不能继承
  WriteINIStr "$StateDir\state.ini" "state" "Ticks" "2147483000"
  Call ReadState
  !insertmacro CheckLabel "5 stale(big ticks) PrevAlive=0" "0" "$PrevAlive"
  ${If} ${FileExists} "$StateDir\state.ini"
    FileWrite $9 "[FAIL] 5 stale file should be deleted$\r$\n"
  ${Else}
    FileWrite $9 "[PASS] 5 stale file deleted$\r$\n"
  ${EndIf}

  ; 6. 恢复完必须能清干净 —— 连目录一起删（状态只在运行期间有意义）
  StrCpy $WasSvc 1
  StrCpy $WasApp 1
  Call WriteState
  Call ClearState
  ${If} ${FileExists} "$StateDir\state.ini"
    FileWrite $9 "[FAIL] 6 ClearState did not delete file$\r$\n"
  ${Else}
    FileWrite $9 "[PASS] 6 ClearState deletes file$\r$\n"
  ${EndIf}
  ${If} ${FileExists} "$StateDir\*.*"
    FileWrite $9 "[FAIL] 6 state dir should be removed$\r$\n"
  ${Else}
    FileWrite $9 "[PASS] 6 state dir removed$\r$\n"
  ${EndIf}

  ; 7. 陈旧状态连同目录一起清掉（跨开机遗留的残留）
  CreateDirectory $StateDir
  StrCpy $WasSvc 1
  StrCpy $WasApp 1
  Call WriteState
  WriteINIStr "$StateDir\state.ini" "state" "Ticks" "2147483000"
  Call ReadState
  !insertmacro CheckLabel "7 stale PrevAlive=0" "0" "$PrevAlive"
  ${If} ${FileExists} "$StateDir\*.*"
    FileWrite $9 "[FAIL] 7 stale dir should be removed$\r$\n"
  ${Else}
    FileWrite $9 "[PASS] 7 stale dir removed$\r$\n"
  ${EndIf}

  FileWrite $9 "=== done ===$\r$\n"
  FileClose $9
SectionEnd