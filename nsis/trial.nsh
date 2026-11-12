; ============================================================================
;  有效期：编译时间常量 + 到期拒绝运行
;  ---------------------------------------------------------------------------
;  设计要点：**到期日是编译期算好、烧进 exe 的常量**，运行时不做任何日期推算。
;    - 构建脚本算出 BUILD_DATE（编译当天）与 EXPIRE_DATE（编译当天 + 有效天数），
;      通过 /DBUILD_DATE=20261112 /DEXPIRE_DATE=20261212 传进来；
;    - 两者都是 !define 常量，作为立即数编进代码，同时写进版本资源方便核对；
;    - 运行时只取「今天」的 yyyyMMdd，和 EXPIRE_DATE 做一次整数比较 ——
;      yyyyMMdd 是单调递增的整数，直接比大小就是正确的日期比较，
;      不需要闰年/跨月/跨年的任何特殊处理。
;
;  为什么不用 ${__DATE__}：
;    它的格式跟随系统区域设置（"2016/4/1"、"2026年11月12日"…），
;    换台机器编译就可能解析失败或把月/日切错，因而只把它当"人类可读的记录"，
;    计算一律走纯数字的 !define /date 或构建脚本传入的值。
;
;  单独编译（不经 build.ps1、没传 /DEXPIRE_DATE）时：
;    BUILD_DATE 由 !define /date 取编译时刻；因为 NSIS 没有编译期日期运算，
;    EXPIRE_DATE 只能留空 —— 此时退化为运行时用 BUILD_DATE + TRIAL_DAYS 现算，
;    正常构建不会走到这条路径。
;
;  可覆盖的编译期开关：
;    /DTRIAL_DAYS=30       有效天数；<=0 表示不限制
;    /DBUILD_DATE=YYYYMMDD 强制编译日期（测试用）
;    /DEXPIRE_DATE=YYYYMMDD 强制到期日（测试用）
; ============================================================================

!ifndef TRIAL_DAYS
  !define TRIAL_DAYS 30
!endif

; 提示框标题用；主脚本本来就有 APP_NAME，单独引用本文件时给个兜底
!ifndef APP_NAME
  !define APP_NAME "RustDesk Lite"
!endif

; 编译日期（纯数字，与区域设置无关）
!ifndef BUILD_DATE
  !define /date BUILD_DATE "%Y%m%d"
!endif
!ifndef BUILD_DATE_TEXT
  !define /date BUILD_DATE_TEXT "%Y-%m-%d"
!endif
!ifndef BUILD_TIME_TEXT
  !define /date BUILD_TIME_TEXT "%Y-%m-%d %H:%M:%S"
!endif

Var DaysLeft      ; 剩余天数（-1 = 不限制；0 = 今天到期仍可用）
Var TodayInt      ; 今天的 yyyyMMdd（整数）

; ---------------------------------------------------------------------------
;  把 yyyyMMdd 格式化成 yyyy-MM-dd（仅用于显示）
;  输入 $R0 -> 输出 $R1
; ---------------------------------------------------------------------------
Function FormatDate
  StrCpy $R1 "$R0" 4
  StrCpy $2 "$R0" 2 4
  StrCpy $3 "$R0" 2 6
  StrCpy $R1 "$R1-$2-$3"
FunctionEnd

; ---------------------------------------------------------------------------
;  取今天的 yyyyMMdd（整数）到 $TodayInt
; ---------------------------------------------------------------------------
Function GetTodayInt
  ; SYSTEMTIME: 年 月 星期 日 时 分 秒 毫秒，每项 2 字节
  System::Call '*(&i2,&i2,&i2,&i2,&i2,&i2,&i2,&i2) p .R3'
  System::Call 'kernel32::GetLocalTime(p R3)'
  System::Call '*$R3(&i2.R4,&i2.R5,&i2,&i2.R7,&i2,&i2,&i2,&i2)'
  System::Free $R3

  ; 月/日必须补齐 2 位，否则 1 月 5 日会拼成 202615 而错位
  IntFmt $R6 "%02u" $R5
  IntFmt $R8 "%02u" $R7
  StrCpy $R0 "$R4$R6$R8"
  StrCpy $TodayInt $R0
FunctionEnd

; ---------------------------------------------------------------------------
;  有效期检查：过期则提示并退出
; ---------------------------------------------------------------------------
Function CheckTrial
  StrCpy $DaysLeft -1

!if ${TRIAL_DAYS} > 0
  Call GetTodayInt

  ; ---- 到期日：优先用编译期烧进来的常量 ----
!ifdef EXPIRE_DATE
  ; 下界校验：今天早于编译日期说明系统时间被回拨过（或时区/时钟异常），
  ; 这种情况直接按过期处理，避免把时间调回去就能一直用。
  ${If} $TodayInt < ${BUILD_DATE}
    MessageBox MB_OK|MB_ICONSTOP "${APP_NAME}$\r$\n$\r$\n系统时间早于本程序的编译日期，无法校验有效期。$\r$\n请把系统时间校正后重试。$\r$\n$\r$\n编译日期：${BUILD_DATE_TEXT}"
    Quit
  ${EndIf}

  ; 常量路径：今天 > 到期日 才算过期（到期日当天仍可运行）
  ${If} $TodayInt > ${EXPIRE_DATE}
    StrCpy $R0 "${EXPIRE_DATE}"
    Call FormatDate
    StrCpy $R2 $R1               ; 到期日 yyyy-MM-dd（显示用）
    MessageBox MB_OK|MB_ICONSTOP "${APP_NAME}$\r$\n$\r$\n有效期已过，程序不再允许运行。$\r$\n$\r$\n编译日期：${BUILD_DATE_TEXT}$\r$\n有效期至：$R2（共 ${TRIAL_DAYS} 天）$\r$\n$\r$\n请联系提供者获取新版本。"
    Quit
  ${EndIf}

  ; 顺带算出剩余天数，供界面/调试使用
  StrCpy $R0 "${EXPIRE_DATE}"
  Call DateToDays
  StrCpy $R2 $R1
  StrCpy $R0 $TodayInt
  Call DateToDays
  IntOp $DaysLeft $R2 - $R1
!else
  ; 兜底路径：没传 /DEXPIRE_DATE 时用「编译日期 + 有效天数」现算
  ; 只比较 yyyyMMdd 的差值不够（跨月跨年会错），所以换算成天数
  StrCpy $R0 "${BUILD_DATE}"
  Call DateToDays
  StrCpy $R2 $R1                 ; buildDays

  StrCpy $R0 $TodayInt
  Call DateToDays
  StrCpy $R5 $R1                 ; todayDays

  IntOp $DaysLeft $R2 + ${TRIAL_DAYS}
  IntOp $DaysLeft $DaysLeft - $R5

  ${If} $DaysLeft < 0
    MessageBox MB_OK|MB_ICONSTOP "${APP_NAME}$\r$\n$\r$\n有效期已过，程序不再允许运行。$\r$\n$\r$\n编译日期：${BUILD_DATE_TEXT}$\r$\n有效期：${TRIAL_DAYS} 天$\r$\n$\r$\n请联系提供者获取新版本。"
    Quit
  ${EndIf}
!endif
!endif
FunctionEnd

; ---------------------------------------------------------------------------
;  yyyyMMdd -> 距 1970-01-01 的天数（仅兜底路径使用）
;  ---------------------------------------------------------------------------
;  Howard Hinnant 的 days_from_civil，纯整数、无查表、无闰年特判：
;    y -= (m <= 2); era = y/400; yoe = y - era*400
;    doy = (153*(m + (m>2 ? -3 : 9)) + 2)/5 + d - 1
;    doe = yoe*365 + yoe/4 - yoe/100 + doy
;    days = era*146097 + doe - 719468
;  输入 $R0 = yyyyMMdd，输出 $R1。2026 年约 2 万天，32 位整数绰绰有余。
Function DateToDays
  StrCpy $1 $R0 4
  StrCpy $2 $R0 "" 4
  StrCpy $3 $2 2
  StrCpy $4 $2 "" 2

  ${If} $3 <= 2
    IntOp $1 $1 - 1
  ${EndIf}

  IntOp $5 $1 / 400
  IntOp $6 $5 * 400
  IntOp $7 $1 - $6

  ${If} $3 > 2
    IntOp $8 $3 - 3
  ${Else}
    IntOp $8 $3 + 9
  ${EndIf}
  IntOp $9 $8 * 153
  IntOp $9 $9 + 2
  IntOp $9 $9 / 5
  IntOp $9 $9 + $4
  IntOp $9 $9 - 1

  IntOp $R1 $7 * 365
  IntOp $2 $7 / 4
  IntOp $R1 $R1 + $2
  IntOp $2 $7 / 100
  IntOp $R1 $R1 - $2
  IntOp $R1 $R1 + $9

  IntOp $2 $5 * 146097
  IntOp $R1 $R1 + $2
  IntOp $R1 $R1 - 719468
FunctionEnd