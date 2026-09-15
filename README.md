# asset-deploy

asset-collector 一键部署工具

**多仓库文档入口**（四库文档与状态标注）：[`../asset-parser/docs/README.md`](../asset-parser/docs/README.md)

## 简介

目标机器无需任何依赖，只需一行命令即可自动下载运行最新版本。

## 安全模型（fail-closed）

三个一键脚本（bat/ps1/sh）在执行下载的二进制前**必须通过 SHA256 校验**，否则拒绝运行（exit 2）。校验来源按优先级：

1. 环境变量 `ASSET_DEPLOY_SHA256=<hash>`（发布方/运维固定的哈希，最强）；
2. 下载服务器上与二进制同目录发布的 `asset-collector.exe.sha256` / `asset-collector.sha256`（sha256sum 格式：`<hash>  <文件名>`）；
3. 显式逃生开关 `ASSET_DEPLOY_ALLOW_UNVERIFIED=1`（接受未校验二进制，仅限临时调试）。

**发布新版本时的义务**：把 `<binary>.sha256`（sha256sum 格式）与二进制一起上传到所有下载镜像。缓存命中（哈希一致）时跳过下载；哈希不匹配时删除本地缓存并拒绝执行。

脚本产物统一落地在 `%LOCALAPPDATA%\asset-collector`（Windows）/ `~/.cache/asset-collector`（Linux）；采集输出的 XML/DB 也在这里，无需自行做缓存。

## 权限（管理员 / root）

**SMART 属性、健康度、部分序列号需要管理员权限才能读取**（`IOCTL_ATA_PASS_THROUGH` 等接口的访问控制），
非提权运行这些字段会留空 —— 脚本和采集器自己都会给出提示。

因此三个脚本**默认请求提权**：Windows 弹 UAC，Linux 走 `sudo`。设计上只提权**那个已通过 SHA256 校验的二进制**，
脚本本身（下载 + 校验）始终以普通权限运行，不用管理员权限去碰网络。

| 平台 | 行为 |
|---|---|
| Windows（bat / ps1） | 已在管理员会话中则直接用；否则 `Start-Process -Verb RunAs` 提权运行二进制，子进程退出码回传给调用方 |
| Linux（sh） | 已是 root 则直接用；否则 `sudo -E` 运行二进制（`-E` 保留 `HOME`，缓存与输出仍在调用者的家目录）。管道执行时 `sudo` 的密码从 `/dev/tty` 读取，不会被管道吃掉 |

**被拒绝或不可用时不会失败**：UAC 被拒、`sudo` 需要密码但没有终端、系统里没有 `sudo` —— 都会打印原因并
**降级为普通权限继续采集**（只是 SMART 字段为空）。

关闭自动提权：

```powershell
$env:ASSET_DEPLOY_ELEVATE = "0"
```
```bash
export ASSET_DEPLOY_ELEVATE=0
```

> 权衡说明：默认提权等于去掉了"每一步都由人确认"这道闸门 —— 脚本下载并校验过的二进制会直接以管理员身份运行。
> 校验是 fail-closed 的，但哈希与二进制来自同一台服务器，除非用 `ASSET_DEPLOY_SHA256` 固定哈希。
> 想保留人工闸门就设 `ASSET_DEPLOY_ELEVATE=0`，再自行以管理员身份启动。

## 使用方式

**Windows (PowerShell - 推荐):**
```powershell
$tmp = Join-Path $env:TEMP "run_asset_collector.ps1"; irm https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.ps1 -OutFile $tmp; & $tmp
```

**Windows (批处理 - 兼容老系统):**
```batch
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat
```

> 说明：上面是**原始模式**（每次都会重新下载启动脚本，保证拿到最新版本）。
> 默认不会上传到服务端；如需上传请追加 `--upload` 参数（见「参数透传」）。

**Linux (Bash):**
```bash
curl -fsSL https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.sh | bash
```

## 自定义下载地址

**Windows (PowerShell):**
```powershell
$env:ASSET_DEPLOY_RELEASE_URL = "https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows"
irm https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.ps1 | iex
```

**Windows (批处理):**
```batch
set ASSET_DEPLOY_RELEASE_URL=https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows
curl -fsSL https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat
```

**Linux (Bash):**
```bash
export ASSET_DEPLOY_RELEASE_URL="https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/linux"
curl -fsSL https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.sh | bash
```

## CDN/镜像加速下载（推荐）

默认会**优先使用 CDN 镜像**下载（失败自动回落到 GitHub raw / ghproxy）。

- 关闭 CDN（强制 raw 优先）：

**Windows (PowerShell):**
```powershell
$env:ASSET_DEPLOY_USE_CDN = "0"
irm https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.ps1 | iex
```

**Windows (BAT):**
```batch
set ASSET_DEPLOY_USE_CDN=0
curl -fsSL https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat
```

**Linux (Bash):**
```bash
export ASSET_DEPLOY_USE_CDN=0
curl -fsSL https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.sh | bash
```

## 优势

- ✅ **真正一行命令** - 目标机器无需任何依赖
- ✅ **多格式支持** - PowerShell 和批处理双版本支持
- ✅ **下载即校验** - 二进制 SHA256 校验 fail-closed（见上文安全模型），多镜像故障切换
- ✅ **托管链路清晰** - 终端二进制由 GitHub 托管分发（SHA256 校验兜底），代码与产物同源可追溯
- ✅ **自动更新** - 每次运行自动获取最新版本
- ✅ **跨平台支持** - 同时支持 Windows 和 Linux

## 构建交付（更新 bin）

`asset-deploy` 仓库本身主要存放“编译好的 asset-collector 二进制”，不包含独立构建流程。

当你需要更新客户端版本时，按以下顺序操作：

1. 在 `asset-collector` 仓库完成构建（见 [../asset-collector/docs/BUILD.md](../asset-collector/docs/BUILD.md)，含复制到本仓库 bin/ 的完整命令）。
2. **重新生成同名的 `.sha256`**（这一步是发布的一部分，不是可选项）：

```powershell
# Windows（PowerShell）
$h = (Get-FileHash -Algorithm SHA256 "bin\windows\asset-collector.exe").Hash.ToLower()
Set-Content -NoNewline -Encoding ascii "bin\windows\asset-collector.exe.sha256" "$h  asset-collector.exe`n"
```

```bash
# Linux / WSL（注意 sha256sum 默认带 `*`，格式必须是两个空格 + 纯文件名）
( cd bin/linux && printf '%s  asset-collector\n' "$(sha256sum asset-collector | cut -d' ' -f1)" > asset-collector.sha256 )
```

3. 自检（两条都要 PASS）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ..\scripts\build_all.ps1   # 第 8 节 published binaries vs .sha256
```

### 为什么必须重生成哈希

客户端判断"要不要更新"的依据就是**发布的 `.sha256`**（不是版本号）：本地二进制哈希与它一致 → 跳过下载；不一致 → 重新下载并校验。所以哈希一旦与二进制脱节：

| 情况 | 客户端表现 |
|---|---|
| 换了二进制、`.sha256` 没换（还是旧哈希） | 已装机器本地哈希与旧哈希一致 → **永远跳过下载，静默停在旧版本**；新机器下载后校验失败 → `SECURITY REFUSAL` 退出 |
| `.sha256` 换了、二进制没换 | 所有机器每次运行都重下一遍（约 7 MB），校验总能过 |

两种都不报服务端错误，只在终端上表现，所以"改二进制必改哈希"必须当成同一步操作。

> 取不到哈希时脚本会打印每个下载地址的 HTTP 状态码（404 单独给解释），便于区分"没发布哈希"和"地址/分支写错"。

## 参数透传

三个启动脚本都会把你传入的参数原样透传给 `asset-collector`。  
例如你希望客户直接上传到服务端：

**PowerShell:**
```powershell
$tmp = Join-Path $env:TEMP "run_asset_collector.ps1"; irm https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.ps1 -OutFile $tmp; & $tmp --upload http://127.0.0.1:35500/upload
```

**BAT:**
```batch
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat --upload http://127.0.0.1:35500/upload
```

**Bash:**
```bash
./run_asset_collector.sh --upload http://127.0.0.1:35500/upload
```

> 不带 `--quick` 时为普通模式，会提示输入责任人/资产编号/备注（即登记信息）。

默认建议先用 HTTP 本地联调：`http://<server-ip>:35500/upload`（`asset-ingest` 默认监听 35500）。
若你改为自签名 HTTPS，客户端请设置 `ASSET_TLS_INSECURE=1` 或 `ASSET_TLS_CA_PATH`。

### 局域网联调（客户端指向你的机器）

在 `<server-ip>` 上运行 `asset-ingest` 后，客户端一条命令即可采集并上传：

```bash
# Linux 客户端；注意 `bash -s -- --upload` 里的 `--` 不能省略，否则报 bash: --: invalid option
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.sh | bash -s -- --upload http://<server-ip>:35500/upload
```

```powershell
# Windows 客户端（快速模式跳过登记）
$tmp = Join-Path $env:TEMP "run_asset_collector.ps1"; irm https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/run_asset_collector.ps1 -OutFile $tmp; & $tmp --quick --upload http://<server-ip>:35500/upload
```

若服务端启用了 `ASSET_TAKEN_KEY`，客户端需先设置同名环境变量再执行上述命令。
Windows 客户端可先用浏览器打开 `http://<server-ip>:35500/` 确认连通。

## 说明

本仓库直接存放编译好的二进制文件：
- `bin/windows/asset-collector.exe` - Windows 版本
- `bin/linux/asset-collector` - Linux 版本

更新版本只需覆盖重新推送即可。
