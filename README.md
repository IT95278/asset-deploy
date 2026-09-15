# asset-deploy

asset-collector 一键部署工具

**多仓库文档入口**（四库文档与状态标注）：[`../asset-parser/docs/README.md`](../asset-parser/docs/README.md)

## 简介

目标机器无需任何依赖，只需一行命令即可自动下载运行最新版本。

## 安全模型（2026-09-14 起，fail-closed）

三个一键脚本（bat/ps1/sh）在执行下载的二进制前**必须通过 SHA256 校验**，否则拒绝运行（exit 2）。校验来源按优先级：

1. 环境变量 `ASSET_DEPLOY_SHA256=<hash>`（发布方/运维固定的哈希，最强）；
2. 下载服务器上与二进制同目录发布的 `asset-collector.exe.sha256` / `asset-collector.sha256`（sha256sum 格式：`<hash>  <文件名>`）；
3. 显式逃生开关 `ASSET_DEPLOY_ALLOW_UNVERIFIED=1`（接受未校验二进制，仅限临时调试）。

**发布新版本时的义务**：把 `<binary>.sha256`（sha256sum 格式）与二进制一起上传到所有下载镜像。缓存命中（哈希一致）时跳过下载；哈希不匹配时删除本地缓存并拒绝执行。

脚本产物统一落地在 `%LOCALAPPDATA%\asset-collector`（Windows）/ `~/.cache/asset-collector`（Linux），不再散落 `%TEMP%`；采集输出的 XML/DB 也在这里。

## 使用方式

**Windows (PowerShell - 推荐):**
```powershell
$tmp = Join-Path $env:TEMP "run_asset_collector.ps1"; irm https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.ps1 -OutFile $tmp; & $tmp
```

**Windows (批处理 - 兼容老系统):**
```batch
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat
```

> 说明：上面是**原始模式**（每次都会重新下载启动脚本，保证拿到最新版本）。
> 默认不会上传到服务端；如需上传请追加参数：`--upload http://<server-ip>:8080/upload`。

**Linux (Bash):**
```bash
curl -fsSL https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.sh | bash
```

## 自定义下载地址

**Windows (PowerShell):**
```powershell
$env:ASSET_DEPLOY_RELEASE_URL = "https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/bin/windows"
irm https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.ps1 | iex
```

**Windows (批处理):**
```batch
set ASSET_DEPLOY_RELEASE_URL=https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/bin/windows
curl -fsSL https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat
```

**Linux (Bash):**
```bash
export ASSET_DEPLOY_RELEASE_URL="https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/bin/linux"
curl -fsSL https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.sh | bash
```

## CDN/镜像加速下载（推荐）

默认会**优先使用 CDN 镜像**下载（失败自动回落到 GitHub raw / ghproxy）。

- 关闭 CDN（强制 raw 优先）：

**Windows (PowerShell):**
```powershell
$env:ASSET_DEPLOY_USE_CDN = "0"
irm https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.ps1 | iex
```

**Windows (BAT):**
```batch
set ASSET_DEPLOY_USE_CDN=0
curl -fsSL https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat
```

**Linux (Bash):**
```bash
export ASSET_DEPLOY_USE_CDN=0
curl -fsSL https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.sh | bash
```

## 优势

- ✅ **真正一行命令** - 目标机器无需任何依赖
- ✅ **多格式支持** - PowerShell 和批处理双版本支持
- ✅ **下载即校验** - 二进制 SHA256 校验 fail-closed（见下方安全模型），多镜像故障切换
- ✅ **托管链路清晰** - 代码 git 推拉走自建 Gitea；终端二进制分发经 GitHub+镜像（SHA256 校验兜底）
- ✅ **自动更新** - 每次运行自动获取最新版本
- ✅ **跨平台支持** - 同时支持 Windows 和 Linux

## 构建交付（更新 bin）

`asset-deploy` 仓库本身主要存放“编译好的 asset-collector 二进制”，不包含独立构建流程。

当你需要更新客户端版本时，按以下顺序操作：

1. 在 `asset-collector` 仓库完成构建（见 [../asset-collector/docs/BUILD.md](../asset-collector/docs/BUILD.md)，含复制到本仓库 bin/ 的完整命令）。

## 参数透传（已支持）

三个启动脚本都会把你传入的参数原样透传给 `asset-collector`。  
例如你希望客户直接上传到服务端：

**PowerShell:**
```powershell
$tmp = Join-Path $env:TEMP "run_asset_collector.ps1"; irm https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.ps1 -OutFile $tmp; & $tmp --upload http://127.0.0.1:8080/upload
```

**BAT:**
```batch
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.bat -o %TEMP%\run_asset_collector.bat && %TEMP%\run_asset_collector.bat --upload http://127.0.0.1:8080/upload
```

**Bash:**
```bash
./run_asset_collector.sh --upload http://127.0.0.1:8080/upload
```

> 不带 `--quick` 时为普通模式，会提示输入责任人/资产编号/备注（即登记信息）。

默认建议先用 HTTP 本地联调：`http://<server-ip>:8080/upload`（`asset-ingest` 默认监听 8080）。
若你改为自签名 HTTPS，客户端请设置 `ASSET_TLS_INSECURE=1` 或 `ASSET_TLS_CA_PATH`。

## 局域网联调（客户端指向你的机器）

在 `<server-ip>` 上运行 `asset-ingest` 后，客户端一条命令即可采集并上传（参数原样透传）：

```bash
# Linux 客户端；注意 `bash -s -- --upload` 里的 `--` 不能省略，否则报 bash: --: invalid option
curl -fsSL https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.sh | bash -s -- --upload http://<server-ip>:8080/upload
```

```powershell
# Windows 客户端（快速模式跳过登记）
$tmp = Join-Path $env:TEMP "run_asset_collector.ps1"; irm https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/run_asset_collector.ps1 -OutFile $tmp; & $tmp --quick --upload http://<server-ip>:8080/upload
```

若服务端启用了 `ASSET_TAKEN_KEY`，客户端需先设置同名环境变量再执行上述命令。
Windows 客户端可先用浏览器打开 `http://<server-ip>:8080/` 确认连通。

## Windows 脚本缓存模式（可选）

> ⚠️ 2026-09-14 更正：此前推荐的 `curl -fsS -z "%BOOT%" -o "%BOOT%"` 模式有严重缺陷——HTTP 304 时 curl 以空体覆写本地缓存脚本，第二次运行会执行**空脚本**（审计 SUP-50），该模式已废弃。
>
> 现在**无需自行做缓存**：一键脚本内置按哈希判定的缓存（`%LOCALAPPDATA%\asset-collector` / `~/.cache/asset-collector`），二进制哈希与服务器发布的一致时自动跳过下载，既保证最新又保证完整性。直接使用「使用方式」章节的标准命令即可。

## 说明

本仓库直接存放编译好的二进制文件：
- `bin/windows/asset-collector.exe` - Windows 版本
- `bin/linux/asset-collector` - Linux 版本

更新版本只需覆盖重新推送即可。
