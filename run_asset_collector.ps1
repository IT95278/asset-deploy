# IP Collector - One-Click Runner (Windows PowerShell)
# Standardized 2026-09-14 (audit DP-01/DP-03/DP-04/DP-05/DP-06):
#   - SHA256 verification is REQUIRED before execution (fail-closed).
#     Provide a pinned hash via ASSET_DEPLOY_SHA256, or publish "<binary>.sha256"
#     next to the binary on the download server; as a last-resort escape hatch set
#     ASSET_DEPLOY_ALLOW_UNVERIFIED=1 explicitly.
#   - Binary is cached under %LOCALAPPDATA%\asset-collector and outputs land in the
#     same folder (visible), instead of littering %TEMP%.
#   - Exit code of asset-collector is propagated ($LASTEXITCODE).
#   - SMART data / serial numbers need administrator rights, so the runner asks for them
#     by default (UAC) and elevates ONLY the already-verified binary.  A declined prompt
#     falls back to an un-elevated run.  ASSET_DEPLOY_ELEVATE=0 turns the request off.

$ErrorActionPreference = "Stop"

Write-Host "IP Collector - One-Click Runner" -ForegroundColor Cyan

$explicitBaseUrl = $env:ASSET_DEPLOY_RELEASE_URL
# NOTE: keep the URL list identical to run_asset_collector.bat / run_asset_collector.sh.
$defaultRawBaseUrl = "https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows"
$defaultGhProxyOrgBaseUrl = "https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows"
$defaultCdnGhProxyBaseUrl = "https://cdn.gh-proxy.org/https://github.com/IT95278/asset-deploy/raw/main/bin/windows"
$defaultHkGhProxyBaseUrl = "https://hk.gh-proxy.org/https://github.com/IT95278/asset-deploy/raw/main/bin/windows"
$defaultCdnBaseUrl = "https://cdn.jsdelivr.net/gh/IT95278/asset-deploy@main/bin/windows"
$defaultGhProxyBaseUrl = "https://ghproxy.com/$defaultRawBaseUrl"

$baseUrls = @()
if ($explicitBaseUrl) {
    $baseUrls += $explicitBaseUrl
} else {
    $useCdn = $env:ASSET_DEPLOY_USE_CDN
    if (-not $useCdn) { $useCdn = "1" }
    # Case-insensitive on/off parsing (audit DP-04).
    $cdnOff = @("0", "false", "no") -contains $useCdn.ToLowerInvariant()
    if ($cdnOff) {
        $baseUrls += $defaultGhProxyOrgBaseUrl, $defaultCdnGhProxyBaseUrl, $defaultHkGhProxyBaseUrl, $defaultRawBaseUrl, $defaultCdnBaseUrl, $defaultGhProxyBaseUrl
    } else {
        $baseUrls += $defaultGhProxyOrgBaseUrl, $defaultCdnGhProxyBaseUrl, $defaultHkGhProxyBaseUrl, $defaultCdnBaseUrl, $defaultRawBaseUrl, $defaultGhProxyBaseUrl
    }
}

$binaryName = "asset-collector.exe"
$baseDir = Join-Path $env:LOCALAPPDATA "asset-collector"
$binaryPath = Join-Path $baseDir $binaryName

# Windows PowerShell 5.1 on older .NET defaults to TLS 1.0/1.1; GitHub requires TLS 1.2+ (audit DP-05).
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Warning "Could not enable TLS 1.2: $_"
}

function Get-ExpectedSha256 {
    # 1) Pinned via environment (strongest).
    $pinned = $env:ASSET_DEPLOY_SHA256
    if ($pinned) { return @{ Hash = $pinned.Trim().ToLowerInvariant(); Source = "ASSET_DEPLOY_SHA256" } }

    if ($env:ASSET_DEPLOY_ALLOW_UNVERIFIED -eq "1") {
        return $null  # explicit escape hatch; warning printed by caller
    }

    # 2) Published "<binary>.sha256" next to the binary (sha256sum format: "<hash>  <name>").
    $probe = @()
    foreach ($baseUrl in $baseUrls) {
        $hashUrl = "$baseUrl/$binaryName.sha256"
        try {
            Write-Host "  - Trying hash: $hashUrl"
            $res = Invoke-WebRequest -Uri $hashUrl -UseBasicParsing -TimeoutSec 30
            # file:// and some mirrors serve the hash file as a byte[], not text.
            $content = $res.Content
            if ($content -is [byte[]]) {
                $content = [Text.Encoding]::ASCII.GetString($content)
            }
            $text = ("$content").Trim()
            if (-not $text) { continue }
            $firstToken = ($text -split "\s+")[0].ToLowerInvariant()
            if ($firstToken -match "^[0-9a-f]{64}$") {
                return @{ Hash = $firstToken; Source = $hashUrl }
            }
        } catch {
            # No hash published at this mirror; try the next one.  Keep the HTTP status so
            # the refusal below can separate "hash not published" from "wrong URL".
            $code = "unreachable"
            $resp = $_.Exception.Response
            if ($resp -and $resp.StatusCode) { $code = [int]$resp.StatusCode }
            $probe += "$hashUrl -> HTTP $code"
        }
    }
    if ($probe.Count -gt 0) {
        Write-Host "  - no hash retrieved; the mirror answered:" -ForegroundColor Yellow
        foreach ($p in $probe) { Write-Host "      $p" -ForegroundColor DarkGray }
    }
    return $null
}

$expected = Get-ExpectedSha256
# Audit W2-04: the escape hatch returns $null from Get-ExpectedSha256; that must
# proceed with verification skipped (loud warning), not hit the refusal below.
$skipVerify = ($null -eq $expected)
if ($skipVerify) {
    if ($env:ASSET_DEPLOY_ALLOW_UNVERIFIED -ne "1") {
        Write-Host ""
        Write-Host "SECURITY REFUSAL: no SHA256 available for $binaryName." -ForegroundColor Red
        Write-Host "  - publish $binaryName.sha256 (sha256sum format) next to the binary, or"
        Write-Host "  - set ASSET_DEPLOY_SHA256=<hash>, or"
        Write-Host "  - set ASSET_DEPLOY_ALLOW_UNVERIFIED=1 to accept an unverified binary explicitly."
        Write-Host "  - HTTP 404 above means the path/branch is wrong, or the mirror has no content on that branch yet."
        exit 2
    }
    Write-Host "WARNING: ASSET_DEPLOY_ALLOW_UNVERIFIED=1 - SHA256 verification skipped." -ForegroundColor Yellow
}

$needDownload = $true
if (-not $skipVerify -and (Test-Path $binaryPath)) {
    $actual = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -eq $expected.Hash) {
        Write-Host "Cached binary matches expected SHA256; skipping download."
        $needDownload = $false
    } else {
        # The published digest is the version oracle: a different local hash means the
        # cached copy is not the published build (older, or built with other flags), so
        # this is an update rather than a repair.
        Write-Host "Cached binary differs from the published build; re-downloading." -ForegroundColor Yellow
        Write-Host "  local : $($actual.Substring(0,16))..."
        Write-Host "  remote: $($expected.Hash.Substring(0,16))...  ($($expected.Source))"
    }
}

if ($needDownload) {
    New-Item -ItemType Directory -Force -Path $baseDir | Out-Null
    Write-Host "Downloading $binaryName..."
    $maxRetries = 3
    $ok = $false
    foreach ($baseUrl in $baseUrls) {
        Write-Host "  - Trying: $baseUrl/$binaryName"
        for ($i = 1; $i -le $maxRetries; $i++) {
            try {
                Invoke-WebRequest -Uri "$baseUrl/$binaryName" -OutFile $binaryPath -UseBasicParsing -TimeoutSec 120
                if ((Get-Item $binaryPath).Length -lt 1MB) {
                    throw "Downloaded file is suspiciously small (<1MB)."
                }
                $ok = $true
                break
            } catch {
                Write-Host "    Download attempt $i/$maxRetries failed: $_" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
        if ($ok) { break }
    }
    if (-not $ok) {
        Write-Host "Download failed after $maxRetries attempts." -ForegroundColor Red
        exit 1
    }

    # Audit DP-01: verify BEFORE executing (skipped only by the explicit
    # ALLOW_UNVERIFIED escape hatch handled above).
    if (-not $skipVerify) {
    $actual = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected.Hash) {
        Write-Host "SHA256 MISMATCH (source: $($expected.Source))" -ForegroundColor Red
        Write-Host "  expected: $($expected.Hash)"
        Write-Host "  actual:   $actual"
        Remove-Item -Force $binaryPath
        exit 2
    }
    Write-Host "SHA256 verified ($($expected.Source))." -ForegroundColor Green
    }
}

Write-Host "Working directory: $baseDir"
Write-Host "Starting IP Collector..." -ForegroundColor Green
Push-Location $baseDir
try {
    # ---- Elevation: SMART data / serial numbers need administrator rights (see README) ----
    # Only the verified binary is elevated; the download + verify above stays user-level,
    # so that step never holds the privilege.  ASSET_DEPLOY_ELEVATE=0 opts out; a declined
    # UAC prompt falls back to an un-elevated run.
    $elevateWanted = $env:ASSET_DEPLOY_ELEVATE -notmatch '^(?i:0|false|no)$'
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elevateWanted -and -not $isAdmin) {
        Write-Host "Requesting administrator rights for SMART/serial collection (approve the UAC prompt)..." -ForegroundColor Yellow
        try {
            # NOTE: "$args" must NOT be written as "@args" here: the @ form is array
            # splatting, which hands the elements to Start-Process as ITS parameters and
            # fails with "cannot find a parameter matching '-no-db'".  Each argument is
            # quoted so paths containing spaces survive the round trip.
            $childArgs = (@($args) | ForEach-Object { '"' + $_ + '"' }) -join ' '
            if ($childArgs) {
                $elevated = Start-Process -FilePath $binaryPath -ArgumentList $childArgs -Verb RunAs -Wait -PassThru
            } else {
                $elevated = Start-Process -FilePath $binaryPath -Verb RunAs -Wait -PassThru
            }
            exit $elevated.ExitCode
        } catch {
            Write-Host "Elevation declined or unavailable; continuing without it." -ForegroundColor Yellow
            Write-Host "  reason: $($_.Exception.Message)" -ForegroundColor DarkGray
            Write-Host "SMART/serial fields will be empty.  Set ASSET_DEPLOY_ELEVATE=0 to silence this." -ForegroundColor Yellow
        }
    }
    & $binaryPath @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
