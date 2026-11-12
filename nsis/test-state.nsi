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

; ---- 被测逻辑：与 RustDeskLite.nsi 中的同名函数保持一致 ----
Function ReadState
  StrCpy $PrevSvc 0
  StrCpy $PrevApp 0
  StrCpy $PrevAlive 0
  ClearErrors
  ReadINIStr $Tmp1 "$StateDir\state.ini" "state" "First"
  ${If} ${Errors}
    Return
  ${EndIf}

  ; 跨开机判定：GetTickCount 在重启后变小，用来识别"上次开机遗留"
  ClearErrors
  ReadINIStr $Tmp2 "$StateDir\state.ini" "state" "Ticks"
  ${If} ${Errors}
    StrCpy $Tmp2 0
  ${EndIf}
  System::Call 'kernel32::GetTickCount() i .r1'
  ${If} $1 < $Tmp2
    Delete "$StateDir\state.ini"
    Return
  ${EndIf}

  StrCpy $PrevAlive 1
  ReadINIStr $Tmp1 "$StateDir\state.ini" "state" "HadSvc"
  StrCpy $PrevSvc $Tmp1
  ReadINIStr $Tmp1 "$StateDir\state.ini" "state" "HadApp"
  StrCpy $PrevApp $Tmp1
FunctionEnd

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

Function ClearState
  Delete "$StateDir\state.ini"
FunctionEnd

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

  ; 6. 恢复完必须能清干净
  StrCpy $WasSvc 1
  StrCpy $WasApp 1
  Call WriteState
  Call ClearState
  ${If} ${FileExists} "$StateDir\state.ini"
    FileWrite $9 "[FAIL] 6 ClearState did not delete$\r$\n"
  ${Else}
    FileWrite $9 "[PASS] 6 ClearState deletes$\r$\n"
  ${EndIf}

  FileWrite $9 "=== done ===$\r$\n"
  FileClose $9
SectionEnd