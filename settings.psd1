@{
    # ========================================================================
    #  构建参数模板（可以安全提交到仓库）
    #  ----------------------------------------------------------------------
    #  ID 服务器地址与 Key 属于私密信息，不要写在这里。
    #  请照本文件的格式新建 settings.local.psd1（已被 .gitignore 忽略），
    #  在里面填写 IdServer / Key / 本机路径等，构建时会自动覆盖同名项。
    # ========================================================================

    # ---- 构建参数 ----
    Source     = 'C:\Program Files\RustDesk'                    # 官方 RustDesk 安装目录（作为载荷来源）
    NsisExe    = 'C:\Program Files (x86)\NSIS\makensis.exe'     # makensis 路径（NSIS 3.x）
    AppName    = 'RustDesk Lite'                                # 生成的单文件程序名
    OutFile    = ''                                             # 为空则输出到 dist\<AppName>.exe
    Mode       = 'lite'                                         # lite = 精简（默认） | full = 全量
    HookDll    = ''                                             # 为空则用 hook\out\SAS.dll

    # ---- 内置服务器配置（写入 [options]） ----
    IdServer    = ''                                            # 例：'rd.example.com' 或 '1.2.3.4:21116'
    Key         = ''                                            # 例：'sB5oad...MEQ='（hbbs 的 public key）
    RelayServer = ''                                            # 中继服务器，留空则由 ID 服务器下发（推荐）

    # ---- 固定密码（可选） ----
    Password    = ''                                            # 留空 = 用随机临时密码；填写后写入 RustDesk.toml

    # ---- 更新检查（可选） ----
    # 默认关闭（写入 RustDesk_local.toml 的 enable-check-update = 'N'）。
    # 想保留上游的检查更新行为，加 -CheckUpdate 开关即可。
    CheckUpdate = $false

    # ---- 有效期（可选） ----
    # 从编译当天起算的天数，编译时会把「到期日」算好写死进 exe，超过就不再允许运行。
    # 0 或负数 = 不限制。
    TrialDays   = 30
}
