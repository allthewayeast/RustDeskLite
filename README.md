# RustDesk Lite

把官方 RustDesk 打包成**单文件、双击即用、退出无痕**的便携启动器。

- 生成物是一个约 23.5 MB 的 `RustDeskLite.exe`，双击后自动解压到 `%TEMP%\RustDesk` 并运行；
- 程序退出后删除解压目录，**不修改、不残留** `%APPDATA%\RustDesk`；
- 本机已安装的 RustDesk 会被临时接管，退出时自动恢复原来的运行状态；
- 已在 RustDesk 1.5.1（Windows 10/11 x64）上完整验证。

> 仓库只包含构建脚本、NSIS 启动器和 Hook 源码，**不包含 RustDesk 本体，也不包含任何服务器地址或 Key**。

---

## 1. 特性

| 特性 | 说明 |
|---|---|
| 单文件 | LZMA 固实压缩，79 MB 载荷压到 23.5 MB |
| 无痕 | 解压到 `%TEMP%\RustDesk`，退出后整个删掉 |
| 不动用户配置 | 配置在**进程内**重定向到解压目录，`%APPDATA%\RustDesk` 全程只读 |
| 内置服务器 | ID 服务器 / Key 写在生成的 `RustDesk2.toml` 里，运行时零配置 |
| 可选固定密码 | 构建时把永久密码写进 `RustDesk.toml`，被控端无需临时密码 |
| 默认不查更新 | `RustDesk_local.toml` 里关掉 `enable-check-update`，避免被提示升级（`-CheckUpdate` 可开回） |
| 关闭即隐藏 | 点右上角 ✕ 只隐藏窗口、进程留在托盘，与正式版一致；托盘「退出」才真正结束 |
| 不显示被控小窗 | 被控时右上角的连接管理窗口（`--cm` 进程）被持续压制，并从任务栏与 Alt+Tab 中摘除，被控者看不到任何提示 |
| 不砸已装版本 | 启动前记录服务与进程状态，退出后按原样恢复 |
| 重复运行 | 已经开着时再双击，会把已有窗口还原并置前，而不是开第二个实例 |
| 崩溃自愈 | 上次被强杀留下的临时目录、互斥锁会自愈，不会卡住下一次启动 |
| 可设有效期 | 编译时把到期日写死进 exe，过期拒绝运行（默认 30 天，`-TrialDays 0` 关闭） |

---

## 2. 工作原理

```
RustDeskLite.exe  (NSIS 启动器，单文件)
   │
   ├─ 0. 互斥判定：已有实例在跑？
   │     ├─ 是 → 找到它的主窗口，ShowWindow + SetForegroundWindow，然后自己退出
   │     └─ 否 → 继续
   │
   ├─ 1. 清掉 %TEMP%\RustDesk 旧残留（被占用则换用 %TEMP%\RustDesk-<id>）
   ├─ 2. 把内置的 79 MB 载荷解压成平铺结构：
   │        rustdesk.exe  *.dll  data\        ← 官方文件
   │        SAS.dll                          ← Hook 壳（见下）
   │        portable                         ← 标记文件：开启便携模式
   │        config\RustDesk2.toml           ← 内置 ID 服务器 / Key
   │        config\RustDesk.toml            ← 可选的固定密码
   │        config\RustDesk_local.toml      ← 本机设置（默认关闭更新检查）
   ├─ 3. 检测本机已安装的 RustDesk（服务 + 进程），记录状态后停掉
   ├─ 4. 先起 rustdesk.exe --tray（便携模式上游不会自动建托盘图标）
   ├─ 5. 起主程序（ExecWait）并等待用户关闭
   ├─ 6. 结束剩余进程 → rmdir 解压目录 → 恢复服务与托盘进程
   └─ 7. 退出
```

### 2.1 为什么能让配置"跟着 exe 走"

RustDesk 的配置目录由 `hbb_common::config::Config::path()` 决定，Windows 上来自
`directories-next` → `SHGetKnownFolderPath(FOLDERID_RoamingAppData)`。
它**不读 `APPDATA` 环境变量**，所以传统的"改环境变量"做法无效。

因此这里改为**在进程内劫持这个 API**：

- `librustdesk.dll` 静态导入 `SAS.dll`（系统里这个 DLL 只有 1 个导出 `SendSAS`，且不在 KnownDLLs），
  把同名的 `SAS.dll` 放到 `rustdesk.exe` 旁边就会被优先加载 —— 这是最小侵入的注入点。
- 壳里用 [MinHook](https://github.com/TsudaKageyu/minhook) 挂 `shell32!SHGetKnownFolderPath`：
  当 exe 目录存在 `portable` 标记时，把 `Roaming` 指向**exe 目录的父目录**——RustDesk 自己会在
  Roaming 后面拼上 `RustDesk`，于是配置正好落回 `<exe目录>\config`（平铺，没有 `appdata` 中间层）。
  没有标记时原样转发，行为完全不变。
- Hook 必须在 `DllMain` 里**同步**安装（RustDesk 在 `DllMain` 返回后立刻读配置，异步装来不及）。

> 顺带记录几个被否掉的方案：
> `version.dll` 劫持不可行（RustDesk 根本不导入它）；
> 改名 / junction / 备份还原 `%APPDATA%` 不可行（一旦新进程被强杀，用户原本的 RustDesk 就会启动异常）。

### 2.2 固定密码、托盘「退出」、去除安装提示与抑制 UAC 探测

- **固定密码**：`RustDesk.toml` 的 `password` 字段支持明文（校验走 `local_permanent_password_storage_matches_plain`，
  直接比对），所以构建时把 `-Password` 原样写进去即可；客户端下次保存配置时会用「机器 UUID 派生的密钥」
  自动转成 `01...` 密文。也正因为密钥与目标机器绑定，**无法在构建机上预先生成密文**。
- **去除「未安装版本」提示**：首页那张红卡的条件是 `Windows && !isDisableInstallation() && !isInstalled()`
  （`desktop_home_page.dart:461`），所以只要让 Dart 侧的 `isDisableInstallation()` 返回 `true` 就不会显示。
  它走 flutter_rust_bridge 生成的导出 `wire_is_disable_installation()`，返回值是
  `WireSyncReturn = *mut DartCObject`，实测是一个 `kArray[bool, bool]`：
  `[0]` 是函数结果、`[1]` 是调用是否成功。
  Hook 的做法是**先调用原函数**拿到由 Rust 正常分配的数组，再只把 `[0]` 的布尔字节改成 `1`：
  结构、所有权、释放路径全部保持原样，Dart 侧读到的仍是合法的 `SyncReturn`。
  > 一定要注意：这个导出**不能**像返回 `int` 的函数那样直接返回 `1`——Dart 会把 `1` 当对象指针解引用，
  > 表现为 WerFault 弹窗 + 界面卡死。所以这里没有"改机器码 `mov eax,1; ret`"的兜底，
  > MinHook 挂不上就放弃（宁可保留提示也不冒崩溃风险）。另一个导出
  > `rustdesk_is_disable_installation` 返回 `int`，那个可以安全地恒返回 1。
  >
  > 安装时机也要注意：这两个钩子必须在**第一次 `SHGetKnownFolderPath` 之后**才装。
  > `DllMain` 阶段本 DLL 正被 `librustdesk.dll` 导入，模块还没就绪，取导出会失败。
  想保留提示：在程序目录放一个名为 `show-install-tip` 的空文件即可。
- **抑制 UAC 探测风暴**：RustDesk 在"未安装"模式下，采集循环**每帧**都会执行一次
  `tasklist | findstr consent.exe` 来探测 UAC 安全桌面（`video_service.rs:750` →
  `is_process_consent_running()`），也就是每帧拉起 cmd + tasklist + findstr 三个进程。
  Hook 在 `CreateProcessW` 里把这条命令换成自带的 2.5 KB 空程序 `rdnop.exe`：
  进程数从 3 降到 1，返回结果同样是"没有 consent.exe"。
  代价：真实 UAC 弹窗的探测会失效——便携模式本来也抓不到安全桌面，影响可忽略。
- **托盘「退出」**：托盘进程（`--tray`）的菜单由 `tray-icon` 库通过 `TrackPopupMenu` 弹出。
  Hook 只在带 `--tray` 的进程里挂 `TrackPopupMenu` / `TrackPopupMenuEx`，命中类名为 `tray_icon_app`
  的窗口时给菜单追加一项「退出 RustDesk」，并 subclass 该窗口的 `WndProc` 截获这个菜单 id。

  > **注意**：`muda 0.17.1` 调 `TrackPopupMenu` 时带了 `TPM_RETURNCMD`，选中项是通过**函数返回值**
  > 交给 `menu_selected` 的，**根本不发 `WM_COMMAND`**。所以早期版本在 `WM_COMMAND` 里拦截
  > 「退出」的写法从未生效（按钮一直是死的）。现在改为在 `Hook_TrackPopupMenu` 的返回值里判断。

  点击「退出」的实际动作见下一节：不能直接发 `WM_CLOSE`（那会被改写成隐藏），而是发自定义消息。

- **关闭即隐藏**：正式版点右上角 ✕ 只是隐藏窗口，进程留在托盘。便携版原本会直接退出，原因是
  Dart 侧的 `windowManager.setPreventClose(true)`（`main.dart:112`）**没有 await**，初始化竞态下
  可能没生效，于是 `WM_CLOSE` 落到 `DefWindowProc` → `DestroyWindow` → `WM_DESTROY` →
  `PostQuitMessage(0)`（`runner/main.cpp:185` 设了 `quit_on_close=true`），进程立刻消失。

  Hook 在主窗口上 subclass `WndProc` 拦 `WM_CLOSE`，改为 `SW_HIDE`，与正式版对齐。三个配套细节：

  | 场景 | 处理 |
  |---|---|
  | 用户点 ✕ | `ShowWindow(SW_HIDE)`，进程存活，窗口留在托盘 |
  | 托盘「退出」 | 托盘进程投 `WM_RDLITE_QUIT`（`WM_APP+0x51`）→ 置退出标志 → 重投 `WM_CLOSE` 放行给 `DefWindowProc`，走原生销毁链 |
  | 关机 / 注销 | 拦 `WM_QUERYENDSESSION` 返回 `TRUE` 并置标志，后续 `WM_CLOSE` 放行，否则会拦住系统关机 |

  为什么要绕这么一圈：
  - `PostThreadMessageW(tid, WM_QUIT)` **不可行** —— 跨进程投递线程消息需要目标线程的消息队列句柄
    （对方线程首次调 user32 时内核才创建，外部拿不到），实测直接返回 `FALSE`，按钮又变回死的。
  - 只调 `PostQuitMessage()` **也不够** —— 消息能到达，但 Flutter 运行时不止一个消息泵，进程照样存活。

  隐藏后恢复窗口靠托盘的「打开」，或者再双击一次 exe：单实例逻辑会 `ShowWindow(SW_NORMAL)` +
  `SetForegroundWindow` 唤醒已有窗口（实测窗口句柄不变、进程数不增）。

  这带来一个连带影响：NSIS 里 `ExecWait` 原本等主进程退出后才做 `taskkill` 和清理临时目录，
  现在主进程可能长期不退出。链路仍然成立 —— 用户从托盘真正「退出」后 `ExecWait` 返回，
  清理照常执行（已实测：退出后 3 个进程全部结束、`%TEMP%\RustDesk` 被删干净）。
  卸载走的是 `taskkill /F`，绕过 `WM_CLOSE`，不受影响。

- **不显示「连接管理窗口」（被控时右上角那个小窗）**：被控端收到连接时，
  `server/connection.rs:6412` 的 `start_ipc()` 会拉起一个 `--cm` 进程，就是它。
  屏幕右上角、固定 300x490（`kConnectionManagerWindowSizeClosedChat`）、带 Tab 和红色「断开连接」。

  **上游本来就有隐藏开关，但三道门都过不去**，所以只能在 Hook 层处理：

  | 门 | 位置 | 为什么过不去 |
  |---|---|---|
  | ① 三个前置配置 | `password_security.rs:88` `hide_cm()` | 需要 `approve-mode='password'` + `verification-method='use-permanent-password'` + `allow-hide-cm='Y'` —— 这几项可以写进 `RustDesk2.toml` |
  | ② Pro/定制版判断 | `ipc.rs:998` | 只有 `is_pro() \|\| is_custom_client()` 才返回该值，否则直接 `None`。我们 `APP_NAME` 是 `"RustDesk"` → `is_custom_client()` 为 false，**配置写对了也白搭** |
  | ③ `custom.txt` 改名 | `common.rs:2617` | 想改 `app-name` 绕过②，但要 `sign::verify()` 用官方私钥验签，伪造不了 |

  实现（`hook/sas_proxy.c` 的 `HideCmWindowThread`）：只有在 `--cm` 进程里才启动，
  **每 100ms 检查一次并压制** —— 不能用一次性处理，因为
  `server_model.dart` 在 168/175/284/286/524/526/570 等多个时机都会重新 `showCmWindow()`。

  **光 `ShowWindow(SW_HIDE)` 不够：任务栏会留一个图标。** 根因是窗口在
  `flutter/windows/runner/win32_window.cpp` 里用 `CreateWindow(..., WS_OVERLAPPEDWINDOW, ...)`
  创建，**不传任何 `WS_EX_*`**，就是个普通应用窗口，任务栏必然出按钮。
  `SW_HIDE` 只清 `WS_VISIBLE`，不摘任务栏条目。

  所以 `MakeToolWindow()` 做两件事，缺一不可：

  ```c
  ex |= WS_EX_TOOLWINDOW;    // 不进任务栏、不进 Alt+Tab
  ex &= ~WS_EX_APPWINDOW;    // 抵掉"强制上任务栏"的位
  ```

  `WS_EX_APPWINDOW` 优先级高于 `WS_EX_TOOLWINDOW`，只加 TOOLWINDOW 不生效。
  改完再 `ShowWindow(SW_HIDE)` 一次，让任务栏重建按钮。

  实测对照（同一台被控机）：

  | 场景 | `hwnd` | `WS_EX` | `IsWindowVisible` | 任务栏 |
  |---|---|---|---|---|
  | 正式版（未打补丁） | `0x90041C` | `0x00080108` `[LAYERED\|TOPMOST]` | True | **有图标** |
  | 便携包（本补丁生效） | `0x3F00FC` | `0x00080188` `[TOOLWINDOW\|LAYERED\|TOPMOST]` | False | **无图标** |

  稳定性验证：对同一个 CM 窗口连续采样 4 次（跨越 45 秒，中间有真实连接连入），
  `hwnd` / `WS_EX` / `visible` 三个值始终不变，`TOOLWINDOW=True`、`taskbar=False`，没有闪现或回退。

  识别真实 CM 窗口要排除两个坑：
  - Flutter 引擎自带一个 **1x1、坐标在屏幕外**（实测 `@(-21280,-20187)`）的辅助窗口，
    类名同样是 `FLUTTER_RUNNER_WIN32_WINDOW`，会先被 `EnumWindows` 捞到；
  - **不能只按尺寸排除**：CM 窗口被 `minimize()` 之后，`GetWindowRect` 返回的是
    `(-32000,-32000)` 起算的"最小化矩形"，实测只有 **160x28**，高度比 50 还小，
    按尺寸过滤会把它误杀。判据是「**最小化状态直接放行；非最小化时按面积择优**」——
    1x1 辅助窗口面积只有 1，天然垫底，而且它从不最小化。

  顺带改变：`--cm` 进程**不再**跑 `ShowWindowThread`（那个是"把窗口强制显示出来"的），
  否则两个线程会互相打架。实测日志依次出现
  `cm window found, suppressing <hwnd>` 与
  `cm window ex-style -> TOOLWINDOW (removed from taskbar)`。

### 2.3 有效期（编译时间常量 + 到期拒绝运行）

可以把包做成"只能用到某个日期"的限时版，实现见 `nsis\trial.nsh`：

- **编译日期与到期日都是编译期常量**，构建时由 `build.ps1` 算好后通过
  `/DBUILD_DATE=20261112`、`/DEXPIRE_DATE=20261212` 传给 NSIS，作为立即数编进代码；
  同时写进 exe 的版本资源，右键属性就能核对（例如"编译于 2026-11-12 21:06:17；有效期 30 天，2026-12-12 到期"）。
- **运行时不做日期推算**：只取本机今天的 `yyyyMMdd`，和 `EXPIRE_DATE` 做一次整数比较。
  `yyyyMMdd` 是单调递增的整数，直接比大小就是正确的日期比较，闰年、跨月、跨年都不需要特判。
- **到期日当天仍可运行**，`今天 > 到期日` 才拒绝启动。
- **防时间回拨**：如果系统时间早于编译日期，直接按异常处理并退出，
  避免把时钟调回去就能一直用。
- 试 `-TrialDays 0` 可关闭限制。

> 为什么不用 `${__DATE__}`：它的格式**跟随系统区域设置**（`2016/4/1`、`2026年11月12日`…），
> 换台机器编译就可能解析失败，或把月/日切错位。计算一律用 `!define /date` 的纯数字格式
> （走 `strftime`，与区域设置无关）或构建脚本传入的值；

验证：`pwsh nsis\test-trial.ps1` —— 会编译一组极小 exe，检查常量是否写进 exe、
到期日边界（剩 1 天 / 当天 / 过期 1 天）、时间回拨，以及兜底路径的日期换算与 .NET 是否一致。

### 2.4 重复运行与多版本并发

并发行为分三层，靠一个**编译期 GUID** 区分：

| 情形 | 互斥结果 | 行为 |
|---|---|---|
| 同一次编译的 exe 第三次双击 | 命中 | 把已有实例的窗口还原并置前，自己退出 |
| **不同编译**的 exe（发布新版本后用户直接双击新的） | 未命中（GUID 不同） | **先杀掉旧实例的进程树，再接管** |
| 以上都不适用 | 未命中 | 正常启动 |

互斥名是 `RustDeskLitePortableLauncher_<GUID>`，GUID 由 `build.ps1` 每次编译重新生成
（`[guid]::NewGuid()`），通过 `/DLAUNCH_GUID` 传给 NSIS；单独编译时兜底用编译时间戳
（`!define /date`），同样能保证每次编译唯一。

拆掉旧实例用的是：

```
taskkill /F /T /FI "IMAGENAME eq <启动器名>" /FI "PID ne <自己>"
```

两个细节都是必须的：**`/FI "PID ne 自己"`** 不加就会把自己也杀掉（NSIS 进程名和 exe 名相同）；
**`/T`** 不加会留下旧实例启动的 `rustdesk.exe` 子进程继续占着临时目录。
`taskkill` 返回 128 表示本来就没有匹配进程，属于正常情况。

为什么不用固定互斥名：固定名只能防重复双击。换版本时新 exe 会被旧实例挡住而直接退出，
用户只能先去托盘手动退出旧版 —— 新版"双击就能用"的直觉就断了。

### 2.5 正式版运行状态的交接

便携包启动前会探测本机正式版 RustDesk 的服务与托盘进程是否在跑，退出时按原状恢复。
这个状态必须**落盘**，不能只放在内存里：

- 新版本接管时会 `kill` 掉旧实例，旧实例的清理代码来不及跑，内存里的 `WasSvc` / `WasApp` 就丢了；
- 新实例这时再重新探测，只会得到"正式版没在跑"（已经被旧实例停掉了），
  于是原始状态被覆盖成 0，退出后就不恢复了 —— 用户会以为正式版被弄坏。

所以状态写在 `%LOCALAPPDATA%\RustDeskLite\state.ini`，**只由第一个实例写**，后续实例直接继承：

```ini
[state]
First=1        ; 服务/托盘已被本工具停掉，退出时由继承者负责恢复
HadSvc=1       ; 原本服务在跑
HadApp=1       ; 原本有托盘程序
Stamp=2026-11-13
OwnerPid=12345
Ticks=296453437
```

继承规则：**只要有状态文件就继承，不再重新探测**。上面两种情形下"正式版现在没在跑"
都不代表它原本没在跑，重新探测一定错。

唯一的例外是状态来自上一次开机（实例被强杀后没清理，又重启了机器）。
用 `GetTickCount()`（开机后的毫秒数，重启会归零变小）判断跨了开机，命中就丢弃重测。

清理时机：恢复完服务/托盘后才删 `state.ini`。这样即使恢复途中自己被杀，
下一个实例还能接着恢复。

验证：`pwsh nsis\test-state.ps1` —— 14 项断言，覆盖状态写入/继承/陈旧状态丢弃/清理，
以及同 GUID 命中互斥、不同 GUID 杀掉旧实例且不自杀。不触碰任何真实 RustDesk 进程。

### 2.6 构建产物为什么是"单文件"

`rustdesk.exe` 只有 386 KB，真正的内容是 `librustdesk.dll`(41 MB) + Flutter 引擎和 `data\`。
Flutter 引擎必须在运行时从磁盘加载，无法静态链接进 exe，所以"单文件"只能是自解压壳 —— 本项目就是。

---

## 3. 目录结构

```
RustDeskLite/
├─ build.ps1                构建入口：复制载荷 → 精简 → 写配置 → 注入 Hook → 打包
├─ settings.psd1            参数模板（可提交，不含任何密钥）
├─ settings.local.psd1      本地私密配置（不提交，见 .gitignore）
├─ rd-remote.ps1           调试工具：在远端 Session 2 执行脚本（见 8.1）
├─ rdlite-runner.ps1       rd-remote.ps1 的远端执行器
├─ rd-check-windows.ps1    验收工具：列出各 RustDesk 进程的窗口可见性 / 扩展样式 / 任务栏状态
├─ nsis/
│  ├─ RustDeskLite.nsi      启动器脚本（解压 / 接管 / 启动 / 清理 / 唤起窗口）
│  ├─ trial.nsh            有效期：编译时间常量、到期拒绝运行
│  ├─ test-trial.ps1       有效期自测（边界 / 常量写入 / 时间回拨）
│  ├─ test-state.nsi       并发互斥与状态交接的自测载荷（被测函数与被测逻辑同源）
│  ├─ test-state.ps1       编译并运行上面的自测（14 项断言）
│  └─ app.ico               程序图标（建议 256×256 多尺寸）
└─ hook/
   ├─ sas_proxy.c           SAS.dll 源码：劫持 SHGetKnownFolderPath 等
   ├─ sas.def               导出表（转发 SendSAS）
   ├─ nop.c                 2.5 KB 空程序，替代每帧的 tasklist | findstr
   ├─ build-hook.ps1        编译 SAS.dll / rdnop.exe（自动探测 MSVC + Windows SDK）
   ├─ test-hook.ps1         自测入口：编译并运行各探针
   ├─ test-cm-pick.c        CM 窗口择优逻辑单元测试（最小化 / 1x1 辅助窗口等 6 个场景）
   ├─ test-cm-pick.ps1      编译并运行上面的单元测试
   ├─ test_fake_lib.c       假 librustdesk.dll（按 FRB 真实布局返回数组）
   ├─ test_probe2.c         验证 install-tip Hook 改值不破坏返回结构（假 DLL）
   ├─ test_probe5.c         同上，但加载真实的 librustdesk.dll
   ├─ listimports.ps1       列出 PE 导入表（核对可劫持的 DLL）
   └─ minhook/              第三方 Hook 库（BSD-2-Clause）
```

---

## 4. 构建

### 4.1 前置条件

| 依赖 | 说明 |
|---|---|
| Windows 10/11 x64 | 仅支持 64 位 |
| 官方 RustDesk | 已安装，构建时从安装目录复制载荷（默认 `C:\Program Files\RustDesk`） |
| NSIS 3.x | 提供 `makensis.exe` |
| Visual Studio（含 C++ 桌面开发） | **仅**编译 Hook 时需要，编一次即可 |

### 4.2 步骤

```powershell
git clone https://github.com/allthewayeast/RustDeskLite.git
cd RustDeskLite

# 1) 填入自己的服务器与 Key（该文件不会被提交）
Copy-Item settings.psd1 settings.local.psd1
notepad settings.local.psd1

# 2) 编译 Hook（只需一次，产物 hook\out\SAS.dll）
pwsh hook\build-hook.ps1

# 3) 打包
pwsh build.ps1
# → dist\RustDeskLite.exe
```

`settings.local.psd1` 示例：

```powershell
@{
    Source   = 'C:\Program Files\RustDesk'
    NsisExe  = 'C:\Program Files (x86)\NSIS\makensis.exe'
    IdServer = 'rd.example.com'          # 也可以写 '1.2.3.4:21116'
    Key      = 'sB5oad...MEQ='           # hbbs 的 public key

    Password = ''                        # 固定密码，留空则每次随机
    TrialDays = 30                       # 有效天数，0 或负数 = 不限制
}
```

### 4.3 常用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Source` | `C:\Program Files\RustDesk` | 官方安装目录 |
| `-IdServer` / `-Key` | 来自 settings | 内置到 `RustDesk2.toml` |
| `-Password` | 空 | 内置固定密码，写入 `RustDesk.toml`；留空则用随机临时密码 |
| `-CheckUpdate` | 关 | 默认关闭更新检查（写 `RustDesk_local.toml` 的 `enable-check-update='N'`）；加此项恢复上游行为 |
| `-TrialDays` | `30` | 有效天数，编译时把到期日算好写死进 exe；`0` = 不限制 |
| `-Mode lite\|full` | `lite` | `lite` 删除虚拟显示器驱动、打印机驱动等冗余 |
| `-ExecLevel admin\|user` | `admin` | `user` 不弹 UAC，但无法停止已装版本的**服务** |
| `-OutFile` | `dist\RustDeskLite.exe` | 输出路径 |
| `-ReusePayload` | 关 | 复用已有 `payload\`，只重新打包（改 NSIS 时常用） |
| `-NoIcon` | 关 | 不注入图标 |

---

## 5. 运行时布局

```
%TEMP%\RustDesk\
├─ rustdesk.exe  librustdesk.dll  flutter_windows.dll ...  data\
├─ SAS.dll        ← Hook 壳
├─ portable       ← 标记：存在才启用便携模式
└─ config\
   ├─ RustDesk2.toml   ← 内置的 ID 服务器 / Key（构建时写入）
   ├─ RustDesk.toml    ← 固定密码 / 本次生成的 ID
   ├─ RustDesk_local.toml ← 本机设置（enable-check-update = 'N'）
   └─ ...
```
日志（`log\`）、对端记录等也都在这棵目录里，退出时一并删除。

`config\` 下三份 toml 属于**三套不同的配置对象**，写错文件会静默失效：

| 文件 | 对应 Rust 侧 | 放什么 |
|---|---|---|
| `RustDesk2.toml` | `Config::file()`（全局） | ID 服务器 / Key 等，读 `Config::get_option` |
| `RustDesk.toml` | `Config::file_("")` | 固定密码、设备 ID、UUID |
| `RustDesk_local.toml` | `LocalConfig`（`file_("_local")`） | 本机界面/行为偏好，读 `LocalConfig::get_option` |

判断某个 key 该写哪份，就看它被哪个 `get_option` 读：`Config::get_option` → `RustDesk2.toml`，
`LocalConfig::get_option` → `RustDesk_local.toml`。例如 `enable-check-update` 在
`common.rs:1064` 处走的是 `LocalConfig::get_option`，所以只能写 `RustDesk_local.toml`。
还有第三类 key（如 `hide-stop-service`）读的是 `BUILTIN_SETTINGS`，**只由签名过的 custom client
配置填充，写进任何 toml 都无效**。

一键验证重定向是否生效：把 `SAS.dll` 和空文件 `portable` 放到 `rustdesk.exe` 同目录运行，
配置应出现在该目录下的 `config\`，而 `%APPDATA%\RustDesk` 不变。

自动验证 Hook 本身（不需要启动 RustDesk，也不会动你已装的版本）：

```powershell
pwsh hook\test-hook.ps1            # 假 librustdesk.dll：验证改值逻辑与返回结构
pwsh hook\test-hook.ps1 -Only 5    # 真实 librustdesk.dll：把 DLL 复制到 out\selftest\RustDesk 里跑
```

`probe5` 必须让 `SAS.dll` 与 `librustdesk.dll` 处在**同一个名为 `RustDesk` 的目录**，
否则 `librustdesk.dll` 会去 System32 找系统自带的 `SAS.dll`，Hook 根本不参与。

---

## 6. 已知限制

- **没有服务**。托盘图标是"窗口开着时的快捷入口"；点 ✕ 只隐藏窗口（进程留在托盘），
  从托盘「退出」才真正结束进程并清理临时目录。
- **每次运行都是新 ID**（配置不落盘），无人值守、固定 ID 的场景不适用。
- **默认需要管理员**：为了停止本机已装 RustDesk 的服务。用 `-ExecLevel user` 打包可以不弹 UAC，但停不了服务。
- **不能和已安装的 RustDesk 同时运行**：RustDesk 自身是全局单实例，启动器会先把它停掉（并询问确认），退出后恢复。
- 托盘提示语仍是上游文案"服务已运行"，便携模式下字面不准。
- 托盘右键菜单已被 Hook 改写：**去掉「停止服务」**（点击会 `sc delete` 掉正式版的服务），
  并额外加一项「退出 RustDesk」（点击投递 `WM_RDLITE_QUIT` 让主进程真正退出）。
  注意 `hide-stop-service` 写进 `RustDesk2.toml` 的 `[options]` **无效** —— 它属于 builtin 设置，
  只由签名过的 custom client 配置填充，`tray.rs` 读的是 `get_builtin_option`，所以只能在菜单层处理。
- **设置页「服务」卡片的 Stop 按钮尚未拦截**：它走 `set_option("stop-service","Y")` →
  `is_installed()` → `uninstall_service()` → `sc delete RustDesk`。而便携版里 `is_installed()`
  会因 `C:\Program Files\RustDesk\RustDesk.exe` 存在而返回 true（同一判断也被用来隐藏首页红卡）。
- **关闭钩子依赖窗口已存在**：`WM_CLOSE` 拦截是在 `ShowWindowThread` 找到主窗口后装的。
  如果主窗口在 15 秒内一直没出现，钩子不会装上，此时点 ✕ 仍会直接退出。
- **连接管理窗口隐藏后，被控者完全没有提示**：屏幕上看不到任何东西，也不知道有人在操作。
  请只在**自己可控的设备**或**已明确告知对方**的场景下使用该打包产物。
- **CM 窗口的压制靠轮询，不是事件驱动**：`HideCmWindowThread` 每 100ms 扫一次窗口，
  理论上存在最多 100ms 的闪现窗口期。实测（`ex` 改完后 `vis=False`、任务栏无按钮）未观察到闪现，
  但如果 Flutter 改版后 `showCmWindow()` 的调用时序变化，可能需要重新评估。
- **Hook 只在便携解压目录里生效**：`SAS.dll` 与 `portable` 标记必须同在 exe 旁。
  直接跑已安装的正式版（`C:\Program Files\RustDesk`）不会加载它，CM 窗口仍会出现在任务栏。
- **调试通道会打断隧道**：用 `rd-remote.ps1` 重启被控端的便携实例，会连带切断承载端口转发的
  SSH 会话（见 8.1）。验证窗口改动时请让对面手动重启。

---

## 7. 安全与合规

- 仓库**不含**服务器地址与 Key。密钥只存在于本机 `settings.local.psd1` 和构建出的 exe 里。
- 仓库**不含** RustDesk 源码或二进制，构建时从你本机已安装的官方版本复制。
- RustDesk 本体采用 AGPL-3.0，**分发打包产物时请遵守其许可**（保留版权与许可声明）。
- Hook 使用 MinHook（BSD-2-Clause，见 `hook/minhook/LICENSE.txt`）。
- 请仅在**自己可控的设备与自建服务器**上使用。

---

## 8. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| `未配置 IdServer` | 没有 `settings.local.psd1`，或里面 `IdServer` 为空 |
| `缺少 Hook DLL` | 先跑 `hook\build-hook.ps1`，产物在 `hook\out\SAS.dll` |
| 双击后配置仍写进 `%APPDATA%` | 检查解压目录里 `SAS.dll` 与 `portable` 是否都在；RustDesk 必须是 x64 |
| 提示 RustDesk 正在运行并被询问 | 本机已装版本在跑，选"是"会先停掉它，退出后自动恢复 |
| 关闭后临时目录没删掉 | 确认没有别的程序占用该目录（比如资源管理器停在里面） |
| 窗口类问题（隐藏、任务栏图标）怎么验证 | 见下方「远程调试窗口状态」 |

### 8.1 远程调试窗口状态（跨 Session 的坑）

排查窗口相关问题时有个很隐蔽的坑：**通过 RustDesk 端口转发进去的 SSH 落在 Session 0（services），
而 GUI 窗口在 Session 2（console）。** 跨 session 调 `EnumWindows` 只能看到 Session 0 的窗口，
永远拿不到 CM 窗口和主窗口的真实状态 —— 会误以为"窗口不存在"或"代码没生效"。

解决办法和 RustDesk 平台层同思路（`src/platform/windows.cc:250` `LaunchProcessWin()`）：
用**计划任务**把进程塞进交互式 session。

```powershell
# 在远端 Session 2 里执行任意 PowerShell 脚本
.\rd-remote.ps1 -ScriptFile .\your-script.ps1 -RemoteUser 'MYPC\Administrator'
```

`rd-remote.ps1` 会：上传脚本 → 渲染任务 XML（`LogonType=InteractiveToken` + `RunLevel=HighestAvailable`）
→ `schtasks /create /xml` → 运行 → 轮询取回 `C:\Windows\Temp\rdlite\out.txt`。

需要传入的参数：

| 参数 | 说明 |
|---|---|
| `-ScriptFile` | 要在远端执行的 `.ps1`（必填） |
| `-RemoteUser` | 计划任务的 `UserId`，必须在被控机上 `whoami` 取值（域名大小写敏感，写成 `HOST\User`） |
| `-RemoteHost` / `-RemotePort` | SSH 入口，默认 `127.0.0.1:10022`（RustDesk 端口转发） |
| `-SshUser` | SSH 登录名，默认 `Administrator` |
| `-AskPass` | 一个只 `echo` 密码的 `.bat`，默认同目录 `askpass.bat`（已在 `.gitignore`，不会提交） |

> `SSH_ASKPASS` 助手在 Windows 上**必须是 `.bat`**，用 `.sh` 会报 `CreateProcessW failed error:193`。

踩过的坑都已经在脚本里处理掉了，改脚本时别退回去：

| 坑 | 表现 | 处理 |
|---|---|---|
| `/tr` 内联传参 | 经 SSH 后引号被剥掉，任务命令行被截断 | 改用 `schtasks /create /xml` |
| `/it` 参数 | 单独用不可靠 | XML 里写 `LogonType=InteractiveToken` |
| XML 编码 | 声明 `UTF-16` 却写成 UTF-8 BOM → `(1,2) 不正确的文档语法` | 用 `UnicodeEncoding(bigEndian:$false, byteOrderMark:$true)` |
| `powershell.exe` 5.1 | `Get-Process` 无 `CommandLine` 属性、CIM 可能被安全策略拦 | 换 pwsh 7（`C:\Program Files\PowerShell\7\pwsh.exe`） |
| runner 内攒 buffer 再写文件 | payload 里调 `Add-Type` 会卡住，输出文件永不生成 | 用 `& $Script *>> $Out` 让 PowerShell 自己重定向 |
| 任务报成功但读不到文件 | 只是读得太早 | 轮询等 `out.txt` 出现 |

> **注意：不要用这套通道去重启被控端的 RustDesk。** 端口转发隧道正是由那条会话承载的，
> 杀掉便携实例会把自己的 SSH 一起断掉，只能等对面人工恢复。

判断窗口是否还会在任务栏出按钮，看两个值就够了：`WS_EX`（`0x80`=`TOOLWINDOW`、`0x40000`=`APPWINDOW`）
和 `IsWindowVisible`。顶层窗口只要 `visible && !TOOLWINDOW && !APPWINDOW`，任务栏就会有按钮。

现成的验收脚本（同样要走上面的通道，在 Session 2 里跑）：

```powershell
.\rd-remote.ps1 -ScriptFile .\rd-check-windows.ps1 -RemoteUser 'MYPC\Administrator'
```

它按进程打印 tag（`CM` / `TRAY` / `SVC` / `SRV` / `TERM` / `MAIN`）、是否便携实例，
以及每个 `FLUTTER_RUNNER_WIN32_WINDOW` 窗口的 `vis` / `iconic` / 尺寸 / `ex` / `taskbar` / 标题。
判定通过的样子：

```
pid=11040 [CM] [PORTABLE]
    hwnd=3F00FC vis=False iconic=True 160x28 ex=0x00080188 [TOOLWINDOW|LAYERED|TOPMOST] taskbar=False
```

注意 `160x28` 是窗口 minimize 之后 `GetWindowRect` 返回的"最小化矩形"，
**不要拿尺寸去判断它是不是 CM 窗口**，要看 `IsIconic()`（见 2.2 节的坑）。

---

## 9. 许可

本仓库自有代码（`build.ps1`、`nsis/`、`hook/` 中除 MinHook 外的部分）采用 MIT。
随附的 MinHook 遵循其 BSD-2-Clause 许可；RustDesk 本体遵循 AGPL-3.0。
