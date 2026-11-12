; ============================================================================
;  RustDesk Lite —— 单文件便携启动器（按需解压 + 进程内重定向 + 全量清理）
;  ---------------------------------------------------------------------------
;  目录结构（平铺，无 app 子目录）：
;    %TEMP%\RustDesk\
;        rustdesk.exe  *.dll  data\          ← 官方文件
;        SAS.dll                             ← 劫持壳（把 %APPDATA%\RustDesk 重定向到这里）
;        portable                            ← 通知壳：启用便携模式
;        config\RustDesk2.toml               ← 内置 ID 服务器 / Key
;        config\RustDesk.toml                ← 可选的固定密码
;        config\、log\、peers\ ...           ← 运行时生成，退出即删
;
;  流程：清理旧残留 → 解压 → 写标记与配置 → 记录并停止已装 RustDesk
;        → 启动→ 等待退出 → 结束进程 → 删目录 → 恢复服务/托盘
;
;  重复运行：已有实例在跑时，不再启动第二个，而是把它自己的窗口
;  （按进程路径匹配 %TEMP%\RustDesk 下的 rustdesk.exe）还原并提到前台。
;
;  所有清理逻辑都在本脚本内完成，不依赖任何外部脚本。
; ============================================================================

Unicode true
SetCompressor /SOLID lzma
SetCompressorDictSize 64

!include "LogicLib.nsh"
!include "StrFunc.nsh"
${StrStr}

; ---------------------------- 可覆盖的编译期参数 ----------------------------
!ifndef APP_NAME
  !define APP_NAME "RustDesk Lite"
!endif
!ifndef OUT_FILE
  !define OUT_FILE "..\dist\RustDesk-Lite.exe"
!endif
!ifndef PAYLOAD_DIR
  !define PAYLOAD_DIR "..\payload"
!endif
!ifndef APP_EXE_REL
  !define APP_EXE_REL "rustdesk.exe"
!endif
!ifndef APP_IMAGE
  !define APP_IMAGE "rustdesk.exe"        ; 进程名（用于检测/结束）
!endif
!ifndef APP_ARGS
  !define APP_ARGS ""
!endif
!ifndef EXEC_LEVEL
  !define EXEC_LEVEL "admin"                ; admin|user
!endif
!ifndef APP_VERSION
  !define APP_VERSION "1.0.0.0"
!endif
; 启动器自身的进程名（用于"未命中互斥时清掉旧版本实例"）。
; 与 APP_IMAGE（被启动的 rustdesk.exe）是两回事，别混。
!ifndef LAUNCHER_IMAGE
  !define LAUNCHER_IMAGE "RustDeskLite.exe"
!endif

; 有效期（编译时间常量、到期拒绝运行）见 trial.nsh
!include "trial.nsh"

; ---------------------------- 并发实例互斥 ----------------------------
; 互斥名里带一个「编译期 GUID」，所以互斥只在**同一次编译出的 exe** 之间生效：
;
;   命中互斥  → 同版本已有实例在跑（重复双击）→ 激活它的窗口，自己退出
;   未命中    → 说明没有同版本实例；可能还留着别的编译版本在跑
;               → 先杀掉它的进程树再接管（否则两个实例会互踩临时目录）
;
; 为什么不用固定名字：固定名字只能防重复双击，换版本时新 exe 会被旧实例
; 挡住（直接退出），用户只能先去托盘退出旧版。带 GUID 后新版本可以直接接管。
!ifndef LAUNCH_GUID
  ; 单独编译（不经 build.ps1、没传 /DLAUNCH_GUID）时的兜底：
  ; 用编译时间戳，同样能保证每次编译唯一
  !define /date LAUNCH_GUID "%Y%m%d%H%M%S"
!endif

Name "${APP_NAME}"
Caption "${APP_NAME}"
OutFile "${OUT_FILE}"
!ifdef APP_ICON
  Icon "${APP_ICON}"
!endif
RequestExecutionLevel ${EXEC_LEVEL}
SilentInstall silent
AutoCloseWindow true
ShowInstDetails nevershow
CRCCheck off
XPStyle on

VIProductVersion "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "ProductName"     "${APP_NAME}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} - 便携启动器"
VIAddVersionKey /LANG=2052 "FileVersion"     "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright"  ""
!if ${TRIAL_DAYS} > 0
  !ifdef EXPIRE_DATE_TEXT
    VIAddVersionKey /LANG=2052 "Comments" "编译于 ${BUILD_TIME_TEXT}；有效期 ${TRIAL_DAYS} 天，${EXPIRE_DATE_TEXT} 到期"
  !else
    VIAddVersionKey /LANG=2052 "Comments" "编译于 ${BUILD_TIME_TEXT}；有效期 ${TRIAL_DAYS} 天"
  !endif
!else
  VIAddVersionKey /LANG=2052 "Comments" "编译于 ${BUILD_TIME_TEXT}"
!endif

Var RootDir      ; 解压根目录（清理时整棵删除）
Var AppDir       ; 程序实际所在目录（Hook 依赖它的名字必须叫 RustDesk）
Var WasSvc       ; 运行前服务是否在跑
Var WasApp       ; 运行前是否有 rustdesk 进程
Var InstExe      ; 已安装的 rustdesk.exe 路径（用于还原托盘）
Var StateDir     ; 启动器状态目录（记录正式版运行状态），退出时整个删掉
Var PrevSvc      ; 从状态文件读回：正式版服务是否原本在跑
Var PrevApp      ; 从状态文件读回：正式版托盘程序是否原本在跑
Var PrevAlive    ; 上面的状态是否来自一个仍在运行的实例
Var Tmp1
Var Tmp2

; 正式版运行状态的持久化（跨实例交接）见 state.nsh。
; 必须放在上面这些 Var 声明之后 —— state.nsh 里的函数直接引用 $StateDir 等变量，
; include 时若变量还没声明，NSIS 会按 StrCpy 的参数个数报错。
!include "state.nsh"

; ================================ 初始化 ====================================
Function .onInit
  Call CheckTrial

  ; 状态目录必须独立于解压目录 $TEMP\RustDesk：
  ; 那个目录在拿到锁后第一件事就是 rmdir（且被占用时会改名成 RustDesk-<uniq>，
  ; 路径不固定），状态文件放进去会在"新版本杀掉旧实例、正要去读它继承"时被自己删掉。
  ; 放 %TEMP%\RustDeskLite 既不会被误删，退出时又能整个删干净（不留痕迹）。
  Call InitState

  ; 互斥：避免重复双击、或上一次的清理还没结束
  StrCpy $5 0
  rd_mutex:
    ; 必须先清零 last error：CreateMutexW 成功时不会重置它，残留的 183 会被误判成“已有实例”
    System::Call 'kernel32::SetLastError(i 0)'
    System::Call 'kernel32::CreateMutexW(p 0, i 0, w "RustDeskLitePortableLauncher_${LAUNCH_GUID}") i .r4 ?e'
    Pop $6
    ${If} $6 != 183
      Goto rd_owned          ; 拿到锁：正常启动流程
    ${EndIf}

    ; ---- 命中了互斥：同一次编译出的实例已经在跑 ----
    System::Call 'kernel32::CloseHandle(p r4)'
    Call FindPortableWindow
    ${If} $R3 != 0
      Call ShowFrontWindow   ; 把它的窗口/任务栏按钮拉到前台
      Quit
    ${EndIf}
    ; 窗口还没出现（可能还在解压/启动中），稍等再看
    Sleep 400
    IntOp $5 $5 + 1
    ${If} $5 < 50          ; 最多等 20s：程序重启/重建窗口期间也能接住
      Goto rd_mutex
    ${EndIf}
    Quit

  rd_owned:
    ; ---- 没命中互斥：没有同版本实例，但可能残留别的编译版本 ----
    ; 不同编译的互斥名不同，所以它们彼此"看不见"，会抢同一个 %TEMP%\RustDesk
    ; 临时目录、互相删对方的文件。这里先按 exe 名把旧实例（含其进程树）清掉。
    ;
    ; 两个必须的细节：
    ;   1) 排除自己 —— 不加 /FI "PID ne <自己>" 会把自己也杀掉；
    ;   2) 带 /T —— 旧实例的 rustdesk.exe 是它的子进程，只杀父进程会留孤儿
    ;      继续占着临时目录，下面 rmdir 就删不掉。
    System::Call 'kernel32::GetCurrentProcessId() i .R0'
    nsExec::Exec 'taskkill /F /T /FI "IMAGENAME eq ${LAUNCHER_IMAGE}" /FI "PID ne $R0"'
    Pop $1
    ; 退 128 = 没有匹配的进程（正常情况：本来就没有旧实例）
    ${If} $1 != 128
      Sleep 500              ; 等文件锁释放，否则临时目录删不干净
    ${EndIf}

  ; 清掉早期版本留下的 ~rd* 临时目录
  FindFirst $1 $2 "$TEMP\~rd*"
  rd_scan:
    StrCmp $2 "" rd_scan_done
    StrCmp $2 "." rd_scan_next
    StrCmp $2 ".." rd_scan_next
    RMDir /r "$TEMP\$2"
  rd_scan_next:
    FindNext $1 $2
    Goto rd_scan
  rd_scan_done:
  FindClose $1
FunctionEnd

; ======================== 重复运行：激活已有窗口 ============================
; 输出 $R3 = 便携实例的主窗口句柄（0 = 没找到）
; 只认“窗口所属进程的可执行文件位于 %TEMP%\RustDesk*”的窗口，
; 避免误拉到本机已安装的 RustDesk 或别的 Flutter 程序。
; 同一进程可能有多个同类窗口（无标题的辅助窗口、启动时隐藏的主窗口），
; 以“有标题”的那个为主窗口——RustDesk 自己也是按标题找窗口的。
Function FindPortableWindow
  StrCpy $R3 0                     ; 最终结果
  StrCpy $R0 0                     ; 兜底候选（第一个路径匹配的窗口）
  StrCpy $R1 0                     ; 遍历游标（上一个窗口，Z 序）
  fpw_loop:
    FindWindow $R2 "FLUTTER_RUNNER_WIN32_WINDOW" "" 0 $R1
    ${If} $R2 == 0
      Goto fpw_done
    ${EndIf}
    StrCpy $R1 $R2
    StrCpy $R5 0
    StrCpy $R7 ""
    StrCpy $R9 0
    System::Call 'user32::GetWindowThreadProcessId(p R2, *i .R5)'
    ${If} $R5 != 0
      System::Call 'kernel32::OpenProcess(i 0x1000, i 0, i R5) p .R6'   ; PROCESS_QUERY_LIMITED_INFORMATION
      ${If} $R6 != 0
        StrCpy $R8 1024
        System::Call 'kernel32::QueryFullProcessImageNameW(p R6, i 0, w .R7, *i R8) i .R9'
        System::Call 'kernel32::CloseHandle(p R6)'
      ${EndIf}
    ${EndIf}
    ${If} $R9 != 0
      ${StrStr} $R4 $R7 "$TEMP\RustDesk"
      ${If} $R4 != ""
        ${If} $R0 == 0
          StrCpy $R0 $R2
        ${EndIf}
        System::Call 'user32::GetWindowTextLengthW(p R2) i .R4'
        ${If} $R4 > 0              ; 有标题 → 主窗口
          StrCpy $R3 $R2
          Return
        ${EndIf}
      ${EndIf}
    ${EndIf}
    Goto fpw_loop
  fpw_done:
    StrCpy $R3 $R0
FunctionEnd

; 把 $R3 指向的窗口还原（最小化时）并提到前台
Function ShowFrontWindow
  System::Call 'user32::IsIconic(p R3) i .R4'
  ${If} $R4 != 0
    System::Call 'user32::ShowWindow(p R3, i 9)'   ; SW_RESTORE
  ${Else}
    System::Call 'user32::ShowWindow(p R3, i 5)'   ; SW_SHOW
  ${EndIf}
  System::Call 'user32::BringWindowToTop(p R3)'
  System::Call 'user32::SetForegroundWindow(p R3) i .R4'
  ${If} $R4 == 0
    ; SetForegroundWindow 受前台锁限制：模拟按一下 ALT 再设
    System::Call 'user32::keybd_event(i 0x12, i 0, i 0, p 0)'
    System::Call 'user32::SetForegroundWindow(p R3) i .R4'
    System::Call 'user32::keybd_event(i 0x12, i 0, i 2, p 0)'
  ${EndIf}
  ${If} $R4 == 0
    ; 仍抢不到前台就闪一下任务栏按钮，至少让用户看到
    System::Call 'user32::FlashWindow(p R3, i 1) i .R4'
  ${EndIf}
FunctionEnd

; =================== 正式版运行状态的持久化（交接给后续实例） ===================
; 实现见 state.nsh（InitState / ReadState / WriteState / ClearState）。
; 抽成单独文件是为了让 nsis\test-state.nsi 直接 include 同一份代码 ——
; 之前测试里放的是手抄副本，改了产品代码忘了同步副本，测试就会谎报通过。

; ================================== 主体 ====================================
Section "main"
  SetShellVarContext current
  SetRegView 64
  StrCpy $WasSvc 0
  StrCpy $WasApp 0

  ; ---- 1. 解压目录：%TEMP%\RustDesk ----
  ; Hook 把 Roaming 换成「程序目录的父目录」，RustDesk 再拼上自己的名字，
  ; 所以程序目录必须叫 RustDesk，配置才会落在 <程序目录>\config。
  ; 用 cmd rmdir 静默删除：NSIS 的 RMDir 遇到被占用的文件会弹错误框并中止
  nsExec::Exec 'cmd /c rmdir /s /q "$TEMP\RustDesk"'
  Pop $0
  StrCpy $RootDir "$TEMP\RustDesk"
  ; 注意：不能用 IfFileExists "$dir\*.*" 判断目录是否存在——目录名没有扩展名时会误判
  System::Call 'kernel32::GetFileAttributesW(w "$RootDir")i .r1'
  ${If} $1 != -1
    ; 还被占用：多半是上次崩溃残留的进程，先按进程名清一次再重试
    nsExec::Exec 'taskkill /F /IM ${APP_IMAGE} /T'
    Sleep 800
    nsExec::Exec 'cmd /c rmdir /s /q "$TEMP\RustDesk"'
    Pop $0
    System::Call 'kernel32::GetFileAttributesW(w "$RootDir")i .r1'
  ${EndIf}

  ${If} $1 == -1
    CreateDirectory "$RootDir"
    StrCpy $AppDir "$RootDir"
  ${Else}
    ; 兜底：换个根名，但把程序放进其下的 RustDesk 子目录，
    ; 这样「父目录 + RustDesk」仍然等于程序目录
    StrCpy $0 0
    rd_dir_uniq:
      IntOp $0 $0 + 1
      System::Call 'kernel32::GetTickCount()i.r1'
      System::Call 'kernel32::GetCurrentProcessId()i.r2'
      StrCpy $RootDir "$TEMP\RustDesk-$1$2$0"
      ClearErrors
      CreateDirectory $RootDir
      IfErrors 0 rd_dir_ready
      IntCmp $0 200 0 rd_dir_uniq rd_dir_uniq
    rd_dir_ready:
      StrCpy $AppDir "$RootDir\RustDesk"
      CreateDirectory "$AppDir"
  ${EndIf}


  ; ---- 2. 解压官方文件（平铺：rustdesk.exe / *.dll / data\） ----
  SetOutPath "$AppDir"
  File /r "${PAYLOAD_DIR}\app\*.*"


  ; ---- 3. 便携标记 + 内置配置 ----
  FileOpen $3 "$AppDir\portable" w
  FileClose $3
  SetOutPath "$AppDir\config"
  File "${PAYLOAD_DIR}\cfg\RustDesk2.toml"
!ifdef HAS_PW
  File "${PAYLOAD_DIR}\cfg\RustDesk.toml"
!endif
; RustDesk_local.toml 对应 LocalConfig（另一份独立配置），有才打进去
!ifdef HAS_LOCAL_CFG
  File "${PAYLOAD_DIR}\cfg\RustDesk_local.toml"
!endif


  ; ---- 4. 记录并停止本机已有的 RustDesk（配置文件一律不碰） ----
  ; 先看有没有前一个实例留下的状态：
  ;   有且仍有效 → 直接继承，不再重新探测（此时正式版已被上一个实例停掉了，
  ;                重新探测只会得到"没在跑"，会把原始状态弄丢）
  ;   没有       → 自己探测，并把自己作为"首个实例"记录下来
  Call ReadState
  ${If} $PrevAlive == 1
    StrCpy $WasSvc $PrevSvc
    StrCpy $WasApp $PrevApp
    StrCpy $7 0              ; 已经停过了，不用再问、也不用再停
    Goto rd_run
  ${EndIf}

  nsExec::ExecToStack 'sc query RustDesk'
  Pop $Tmp2
  Pop $Tmp1
  ${StrStr} $Tmp2 $Tmp1 "RUNNING"
  ${If} $Tmp2 != ""
    StrCpy $WasSvc 1
  ${EndIf}

  nsExec::ExecToStack 'tasklist /FI "IMAGENAME eq ${APP_IMAGE}" /NH'
  Pop $Tmp2
  Pop $Tmp1
  ${StrStr} $Tmp2 $Tmp1 "${APP_IMAGE}"
  ${If} $Tmp2 != ""
    StrCpy $WasApp 1
  ${EndIf}

  ${If} $WasSvc == 1
  ${OrIf} $WasApp == 1
    StrCpy $7 1
  ${Else}
    StrCpy $7 0
  ${EndIf}

  StrCmp $7 0 rd_run
    MessageBox MB_YESNO|MB_ICONQUESTION "${APP_NAME}$\r$\n$\r$\n检测到本机 RustDesk 正在运行。$\r$\nRustDesk 不支持双实例，需要先结束它的服务与托盘程序。$\r$\n$\r$\n· 不会改动任何配置（配置在进程内重定向到临时目录）$\r$\n· 退出本程序后会自动恢复原来的运行状态$\r$\n$\r$\n是否继续？" IDYES rd_stop IDNO rd_cancel
  rd_cancel:
    nsExec::Exec 'cmd /c rmdir /s /q "$RootDir"'
    Pop $0
    Call ClearState          ; 用户放弃：把记录清掉，别留下"假在跑"的状态
    Quit
  rd_stop:
    ; 先落盘再动手：万一这个实例之后被新版本 kill 掉（来不及跑清理），
    ; 下一个实例能从状态文件里继承"正式版原本在跑"，退出时照样能恢复。
    Call WriteState
    nsExec::Exec 'sc stop RustDesk'
    nsExec::Exec 'taskkill /F /IM ${APP_IMAGE} /T'
    nsExec::Exec 'taskkill /F /IM RuntimeBroker_rustdesk.exe /T'
    Sleep 1200
  rd_run:
    ; 走到这里若是"没探测到正式版在跑"的首次运行，也要记一笔，
    ; 这样接管后退出时才知道需不需要恢复（First=1 + HadSvc/HadApp=0 → 不恢复）。
    ${If} $7 == 0
    ${AndIf} $PrevAlive == 0
      Call WriteState
    ${EndIf}


  ; ---- 5. 启动：先拉起托盘进程，再跑主程序并等待 ----
  ; 便携模式上游不会自动建托盘图标（要求已安装且服务在跑），这里手动起一个 --tray
  Exec '"$AppDir\${APP_EXE_REL}" --tray'
  Sleep 600

  SetOutPath "$AppDir"
  ; SET_FOREGROUND_WINDOW=1：让 RustDesk 把主窗口提到前台
  System::Call 'kernel32::SetEnvironmentVariableW(w "SET_FOREGROUND_WINDOW", w "1")'
  ; 必须用 ExecWait 而不是 nsExec：nsExec 带 SW_HIDE 启动，GUI 主窗口会被隐藏
  ExecWait '"$AppDir\${APP_EXE_REL}" ${APP_ARGS}'
  System::Call 'kernel32::SetEnvironmentVariableW(w "SET_FOREGROUND_WINDOW", p 0)'


  ; ---- 6. 清理（全部在脚本内完成） ----
  SetOutPath "$TEMP"
  nsExec::Exec 'taskkill /F /IM ${APP_IMAGE} /T'
  nsExec::Exec 'taskkill /F /IM RuntimeBroker_rustdesk.exe /T'
  Sleep 600

  StrCpy $0 0
  rd_del:
    nsExec::Exec 'cmd /c rmdir /s /q "$RootDir"'
    Pop $1
    System::Call 'kernel32::GetFileAttributesW(w "$RootDir")i .r2'
    ${If} $2 == -1
      Goto rd_del_done
    ${EndIf}
    Sleep 400
    IntOp $0 $0 + 1
    IntCmp $0 12 0 rd_del rd_del
  rd_del_done:


  ; ---- 7. 恢复原有运行状态 ----
  ${If} $WasSvc == 1
    nsExec::Exec 'sc start RustDesk'
  ${EndIf}
  ${If} $WasApp == 1
    ReadRegStr $InstExe HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk" "InstallLocation"
    ${If} $InstExe != ""
      StrCpy $InstExe "$InstExe\rustdesk.exe"
      IfFileExists "$InstExe" 0 rd_no_restore
        Exec '"$InstExe" --tray'
    ${EndIf}
    rd_no_restore:
  ${EndIf}

  ; 恢复完才清状态：如果恢复过程中自己被杀，下一个实例还能接着恢复。
  Call ClearState
SectionEnd
