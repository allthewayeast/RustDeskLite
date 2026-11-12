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
  的窗口时给菜单追加一项「退出 RustDesk」，并 subclass 该窗口的 `WndProc` 截获这个菜单 id，
  向主窗口发 `WM_CLOSE`（主程序退出后启动器会收尾清理）。

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

### 2.4 构建产物为什么是"单文件"

`rustdesk.exe` 只有 386 KB，真正的内容是 `librustdesk.dll`(41 MB) + Flutter 引擎和 `data\`。
Flutter 引擎必须在运行时从磁盘加载，无法静态链接进 exe，所以"单文件"只能是自解压壳 —— 本项目就是。

---

## 3. 目录结构

```
RustDeskLite/
├─ build.ps1                构建入口：复制载荷 → 精简 → 写配置 → 注入 Hook → 打包
├─ settings.psd1            参数模板（可提交，不含任何密钥）
├─ settings.local.psd1      本地私密配置（不提交，见 .gitignore）
├─ nsis/
│  ├─ RustDeskLite.nsi      启动器脚本（解压 / 接管 / 启动 / 清理 / 唤起窗口）
│  ├─ trial.nsh            有效期：编译时间常量、到期拒绝运行
│  ├─ test-trial.ps1       有效期自测（边界 / 常量写入 / 时间回拨）
│  └─ app.ico               程序图标（建议 256×256 多尺寸）
└─ hook/
   ├─ sas_proxy.c           SAS.dll 源码：劫持 SHGetKnownFolderPath 等
   ├─ sas.def               导出表（转发 SendSAS）
   ├─ nop.c                 2.5 KB 空程序，替代每帧的 tasklist | findstr
   ├─ build-hook.ps1        编译 SAS.dll / rdnop.exe（自动探测 MSVC + Windows SDK）
   ├─ test-hook.ps1         自测入口：编译并运行各探针
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
   └─ ...
```
日志（`log\`）、对端记录等也都在这棵目录里，退出时一并删除。

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

- **没有服务**。托盘图标是"窗口开着时的快捷入口"，便携模式下关闭主窗口 = 程序退出。
- **每次运行都是新 ID**（配置不落盘），无人值守、固定 ID 的场景不适用。
- **默认需要管理员**：为了停止本机已装 RustDesk 的服务。用 `-ExecLevel user` 打包可以不弹 UAC，但停不了服务。
- **不能和已安装的 RustDesk 同时运行**：RustDesk 自身是全局单实例，启动器会先把它停掉（并询问确认），退出后恢复。
- 托盘提示语仍是上游文案"服务已运行"，便携模式下字面不准（已用 `hide-stop-service` 隐藏失效菜单）。
- 托盘右键菜单里除上游的「打开」外，额外加了一项「退出 RustDesk」——它是 Hook 在托盘进程里
  劫持 `TrackPopupMenu` 追加的，点了会给主窗口发 `WM_CLOSE`。

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

---

## 9. 许可

本仓库自有代码（`build.ps1`、`nsis/`、`hook/` 中除 MinHook 外的部分）采用 MIT。
随附的 MinHook 遵循其 BSD-2-Clause 许可；RustDesk 本体遵循 AGPL-3.0。
