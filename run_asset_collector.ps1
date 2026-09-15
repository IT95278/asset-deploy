# IP Collector - One-Click Runner (Windows PowerShell)
# Standardized 2026-09-14 (audit DP-01/DP-03/DP-04/DP-05/DP-06):
#   - SHA256 verification is REQUIRED before execution (fail-closed).
#     Provide a pinned hash via ASSET_DEPLOY_SHA256, or publish "<binary>.sha256"
#     next to the binary on the download server; as a last-resort escape hatch set
#     ASSET_DEPLOY_ALLOW_UNVERIFIED=1 explicitly.
#   - Binary is cached under %LOCALAPPDATA%\asset-collector and outputs land in the
#     same folder (visible), instead of littering %TEMP%.
#   - Exit code of asset-collector is propagated ($LASTEXITCODE).

$ErrorActionPreference = "Stop"

Write-Host "IP Collector - One-Click Runner" -ForegroundColor Cyan

$explicitBaseUrl = $env:ASSET_DEPLOY_RELEASE_URL
# NOTE: keep the URL list identical to run_asset_collector.bat / run_asset_collector.sh.
$defaultRawBaseUrl = "https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/bin/windows"
$defaultGhProxyOrgBaseUrl = "https://gh-proxy.org/https://raw.githubusercontent.com/laohuyou886/asset-deploy/main/bin/windows"
$defaultCdnGhProxyBaseUrl = "https://cdn.gh-proxy.org/https://github.com/laohuyou886/asset-deploy/raw/main/bin/windows"
$defaultHkGhProxyBaseUrl = "https://hk.gh-proxy.org/https://github.com/laohuyou886/asset-deploy/raw/main/bin/windows"
$defaultCdnBaseUrl = "https://cdn.jsdelivr.net/gh/laohuyou886/asset-deploy@main/bin/windows"
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
            # No hash published at this mirror; try the next one.
        }
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
        Write-Host "Cached binary hash mismatch; re-downloading." -ForegroundColor Yellow
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
    & $binaryPath @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
