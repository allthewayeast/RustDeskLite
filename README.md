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
| 不砸已装版本 | 启动前记录服务与进程状态，退出后按原样恢复 |
| 重复运行 | 已经开着时再双击，会把已有窗口还原并置前，而不是开第二个实例 |
| 崩溃自愈 | 上次被强杀留下的临时目录、互斥锁会自愈，不会卡住下一次启动 |

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
   │        appdata\RustDesk\config\RustDesk2.toml  ← 内置 ID 服务器 / Key
   ├─ 3. 检测本机已安装的 RustDesk（服务 + 进程），记录状态后停掉
   ├─ 4. 先起 rustdesk.exe --tray（便携模式上游不会自动建托盘图标）
   ├─ 5. 起主程序并等待用户关闭
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
  当 exe 目录存在 `portable` 标记时，把 `Roaming` 重定向到 `<exe目录>\appdata`；否则原样转发，行为完全不变。
- Hook 必须在 `DllMain` 里**同步**安装（RustDesk 在 `DllMain` 返回后立刻读配置，异步装来不及）。

> 顺带记录几个被否掉的方案：
> `version.dll` 劫持不可行（RustDesk 根本不导入它）；
> 改名 / junction / 备份还原 `%APPDATA%` 不可行（一旦新进程被强杀，用户原本的 RustDesk 就会启动异常）。

### 2.2 构建产物为什么是"单文件"

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
│  └─ app.ico               程序图标（建议 256×256 多尺寸）
└─ hook/
   ├─ sas_proxy.c           SAS.dll 源码：劫持 SHGetKnownFolderPath
   ├─ sas.def               导出表（转发 SendSAS）
   ├─ test_probe.c          独立探针，验证重定向是否生效
   ├─ build-hook.ps1        编译 SAS.dll（自动探测 MSVC + Windows SDK）
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
}
```

### 4.3 常用参数

| 参数 | 默认 | 说明 |
|---|---|---|
| `-Source` | `C:\Program Files\RustDesk` | 官方安装目录 |
| `-IdServer` / `-Key` | 来自 settings | 内置到 `RustDesk2.toml` |
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
└─ appdata\RustDesk\
   ├─ config\RustDesk2.toml   ← 内置的 ID 服务器 / Key
   ├─ config\RustDesk.toml    ← 运行时生成（含本次的 ID）
   └─ log\                    ← 日志，随目录一起删除
```

一键验证重定向是否生效：把 `SAS.dll` 和空文件 `portable` 放到 `rustdesk.exe` 同目录运行，
配置应出现在该目录下的 `appdata\RustDesk\config`，而 `%APPDATA%\RustDesk` 不变。

---

## 6. 已知限制

- **没有服务**。托盘图标是"窗口开着时的快捷入口"，便携模式下关闭主窗口 = 程序退出。
- **每次运行都是新 ID**（配置不落盘），无人值守、固定 ID 的场景不适用。
- **默认需要管理员**：为了停止本机已装 RustDesk 的服务。用 `-ExecLevel user` 打包可以不弹 UAC，但停不了服务。
- **不能和已安装的 RustDesk 同时运行**：RustDesk 自身是全局单实例，启动器会先把它停掉（并询问确认），退出后恢复。
- 托盘提示语仍是上游文案"服务已运行"，便携模式下字面不准（已用 `hide-stop-service` 隐藏失效菜单）。

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
