@echo off
setlocal EnableExtensions
chcp 65001 >nul
echo IP Collector - One-Click Runner

rem Standardized 2026-09-14 (audit DP-01/DP-02/DP-03/DP-06):
rem   - SHA256 verification REQUIRED before execution (fail-closed; escape hatch:
rem     ASSET_DEPLOY_ALLOW_UNVERIFIED=1, or pin ASSET_DEPLOY_SHA256, or publish
rem     "%BINARY_NAME%.sha256" next to the binary).
rem   - Binary cached in %%LOCALAPPDATA%%\asset-collector; outputs land there (visible),
rem     no more %%TEMP%% litter.
rem   - Exit code propagated. NOTE: keep URL list identical to run_asset_collector.ps1/.sh.
rem   - SMART data / serial numbers need administrator rights, so the runner asks for them
rem     by default (UAC) and elevates ONLY the already-verified binary.  A declined prompt
rem     falls back to an un-elevated run.  ASSET_DEPLOY_ELEVATE=0 turns the request off.

set "DEFAULT_RAW_BASE_URL=https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows"
set "DEFAULT_GH_PROXY_ORG_BASE_URL=https://gh-proxy.org/https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows"
set "DEFAULT_CDN_GH_PROXY_BASE_URL=https://cdn.gh-proxy.org/https://github.com/IT95278/asset-deploy/raw/main/bin/windows"
set "DEFAULT_HK_GH_PROXY_BASE_URL=https://hk.gh-proxy.org/https://github.com/IT95278/asset-deploy/raw/main/bin/windows"
set "DEFAULT_CDN_BASE_URL=https://cdn.jsdelivr.net/gh/IT95278/asset-deploy@main/bin/windows"
set "DEFAULT_GHPROXY_BASE_URL=https://ghproxy.com/https://raw.githubusercontent.com/IT95278/asset-deploy/main/bin/windows"

set "BASE_URL_LIST="
if "%ASSET_DEPLOY_RELEASE_URL%"=="" (
    if "%ASSET_DEPLOY_USE_CDN%"=="" set "ASSET_DEPLOY_USE_CDN=1"
    if /I "%ASSET_DEPLOY_USE_CDN%"=="0" (
        set "BASE_URL_LIST=%DEFAULT_GH_PROXY_ORG_BASE_URL% %DEFAULT_CDN_GH_PROXY_BASE_URL% %DEFAULT_HK_GH_PROXY_BASE_URL% %DEFAULT_RAW_BASE_URL% %DEFAULT_CDN_BASE_URL% %DEFAULT_GHPROXY_BASE_URL%"
    ) else if /I "%ASSET_DEPLOY_USE_CDN%"=="false" (
        set "BASE_URL_LIST=%DEFAULT_GH_PROXY_ORG_BASE_URL% %DEFAULT_CDN_GH_PROXY_BASE_URL% %DEFAULT_HK_GH_PROXY_BASE_URL% %DEFAULT_RAW_BASE_URL% %DEFAULT_CDN_BASE_URL% %DEFAULT_GHPROXY_BASE_URL%"
    ) else if /I "%ASSET_DEPLOY_USE_CDN%"=="no" (
        set "BASE_URL_LIST=%DEFAULT_GH_PROXY_ORG_BASE_URL% %DEFAULT_CDN_GH_PROXY_BASE_URL% %DEFAULT_HK_GH_PROXY_BASE_URL% %DEFAULT_RAW_BASE_URL% %DEFAULT_CDN_BASE_URL% %DEFAULT_GHPROXY_BASE_URL%"
    ) else (
        set "BASE_URL_LIST=%DEFAULT_GH_PROXY_ORG_BASE_URL% %DEFAULT_CDN_GH_PROXY_BASE_URL% %DEFAULT_HK_GH_PROXY_BASE_URL% %DEFAULT_CDN_BASE_URL% %DEFAULT_RAW_BASE_URL% %DEFAULT_GHPROXY_BASE_URL%"
    )
) else (
    set "BASE_URL_LIST=%ASSET_DEPLOY_RELEASE_URL%"
)

set "BINARY_NAME=asset-collector.exe"
set "BASE_DIR=%LOCALAPPDATA%\asset-collector"
set "BINARY_PATH=%BASE_DIR%\%BINARY_NAME%"
set "HASH_FILE=%TEMP%\asset-collector.expected.sha256"

if not exist "%BASE_DIR%" mkdir "%BASE_DIR%"

rem ---- Determine expected SHA256 (audit DP-01, fail-closed) ----
set "EXPECTED_SHA="
set "EXPECTED_SRC="
if defined ASSET_DEPLOY_SHA256 (
    set "EXPECTED_SHA=%ASSET_DEPLOY_SHA256%"
    set "EXPECTED_SRC=ASSET_DEPLOY_SHA256"
    goto :have_expected
)
if "%ASSET_DEPLOY_ALLOW_UNVERIFIED%"=="1" goto :have_expected
for %%B in (%BASE_URL_LIST%) do (
    if not defined EXPECTED_SHA call :try_hash_url "%%B"
)
if not defined EXPECTED_SHA (
    echo.
    echo SECURITY REFUSAL: no SHA256 available for %BINARY_NAME%.
    echo   - publish %BINARY_NAME%.sha256 ^(sha256sum format^) next to the binary, or
    echo   - set ASSET_DEPLOY_SHA256=^<hash^>, or
    echo   - set ASSET_DEPLOY_ALLOW_UNVERIFIED=1 to accept an unverified binary explicitly.
    echo   - HTTP 404 below means the path/branch is wrong, or the mirror has no content on that branch yet.
    for %%B in (%BASE_URL_LIST%) do call :probe_hash_url "%%B"
    exit /b 2
)
set "EXPECTED_SRC=published .sha256"
:have_expected
rem Audit W2-03: with ALLOW_UNVERIFIED=1 and no pinned/published hash, skip the two
rem hash checks (cache-hit compare and post-download verify) but STILL download when
rem the binary is missing — the previous attempt jumped straight to :run and then
rem failed with "file not found" on a fresh machine.
set "SKIP_VERIFY="
if not defined EXPECTED_SHA (
    set "SKIP_VERIFY=1"
    echo WARNING: ASSET_DEPLOY_ALLOW_UNVERIFIED=1 - SHA256 verification skipped.
)

rem ---- Compute actual hash of cached binary, if present ----
set "ACTUAL_SHA="
if defined EXPECTED_SHA if exist "%BINARY_PATH%" (
    for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%BINARY_PATH%' -Algorithm SHA256).Hash.ToLower()"`) do set "ACTUAL_SHA=%%H"
)

if defined EXPECTED_SHA if defined ACTUAL_SHA if /I "%ACTUAL_SHA%"=="%EXPECTED_SHA%" (
    echo Cached binary matches expected SHA256; skipping download.
    goto :run
)
rem The published digest is the version oracle: a different local hash means the cached
rem copy is not the published build (older, or built with other flags), so this is an
rem update rather than a repair.  Print both short hashes so the transition is visible.
if defined EXPECTED_SHA if defined ACTUAL_SHA (
    echo Cached binary differs from the published build; re-downloading.
    echo   local : %ACTUAL_SHA:~0,16%...
    echo   remote: %EXPECTED_SHA:~0,16%...  ^(%EXPECTED_SRC%^)
)

echo Downloading %BINARY_NAME%...
call :download_from_list
if errorlevel 1 exit /b 1

rem ---- Verify BEFORE executing (audit DP-01); skipped only by ALLOW_UNVERIFIED ----
set "ACTUAL_SHA="
if defined SKIP_VERIFY goto :run
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%BINARY_PATH%' -Algorithm SHA256).Hash.ToLower()"`) do set "ACTUAL_SHA=%%H"
if /I not "%ACTUAL_SHA%"=="%EXPECTED_SHA%" (
    echo SHA256 MISMATCH ^(source: %EXPECTED_SRC%^)
    echo   expected: %EXPECTED_SHA%
    echo   actual:   %ACTUAL_SHA%
    del "%BINARY_PATH%" 2>nul
    exit /b 2
)
echo SHA256 verified ^(%EXPECTED_SRC%^).

:run
echo Working directory: %BASE_DIR%
echo Starting IP Collector...
pushd "%BASE_DIR%"

rem ---- Elevation: SMART data / serial numbers need administrator rights (see README) ----
rem Only the verified binary is elevated; this script stays user-level, so the download +
rem verify above never holds the privilege.  ASSET_DEPLOY_ELEVATE=0 opts out; a declined
rem UAC prompt falls back to an un-elevated run.
rem
rem The child's exit code comes back on stdout, not as our exit code: "if errorlevel N"
rem tests ">= N", so a crashed child (e.g. 0xC0000005) would look like a sentinel value.
set "ELEVATE=%ASSET_DEPLOY_ELEVATE%"
if not defined ELEVATE set "ELEVATE=1"
if /I "%ELEVATE%"=="0"     set "ELEVATE=0"
if /I "%ELEVATE%"=="false" set "ELEVATE=0"
if /I "%ELEVATE%"=="no"    set "ELEVATE=0"
if not "%ELEVATE%"=="1" goto :run_binary
net session >nul 2>&1
if not errorlevel 1 goto :run_binary

echo Requesting administrator rights for SMART/serial collection...
set "ASSET_DEPLOY_CHILD_EXE=%BINARY_PATH%"
set "ASSET_DEPLOY_CHILD_ARGS=%*"
set "ELRC="
for /f "usebackq delims=" %%R in (`powershell -NoProfile -Command "$exe = $env:ASSET_DEPLOY_CHILD_EXE; $a = $env:ASSET_DEPLOY_CHILD_ARGS; try { if ($a) { $p = Start-Process -FilePath $exe -ArgumentList $a -Verb RunAs -Wait -PassThru } else { $p = Start-Process -FilePath $exe -Verb RunAs -Wait -PassThru }; Write-Output $p.ExitCode } catch { Write-Output 'DECLINED' }"`) do set "ELRC=%%R"
set "ASSET_DEPLOY_CHILD_EXE="
set "ASSET_DEPLOY_CHILD_ARGS="
if /I "%ELRC%"=="DECLINED" goto :elevate_declined
if not defined ELRC goto :elevate_declined
set "RC=%ELRC%"
goto :finish

:elevate_declined
echo Elevation declined; continuing without it - SMART/serial fields will be empty.
echo Set ASSET_DEPLOY_ELEVATE=0 to silence this.

:run_binary
"%BINARY_PATH%" %*
set "RC=%ERRORLEVEL%"

:finish
popd
exit /b %RC%

:try_hash_url
rem Sets EXPECTED_SHA (parent scope) from "<url>/<binary>.sha256"; silent no-op on failure.
if defined EXPECTED_SHA exit /b 0
echo   - Trying hash: %~1/%BINARY_NAME%.sha256
curl -fsSL --connect-timeout 8 -o "%HASH_FILE%" "%~1/%BINARY_NAME%.sha256" 2>nul
if not exist "%HASH_FILE%" exit /b 0
rem usebackq + quoted path: read first token of the hash file.
for /f "usebackq tokens=1" %%H in ("%HASH_FILE%") do (
    if not defined EXPECTED_SHA set "EXPECTED_SHA=%%H"
)
del "%HASH_FILE%" 2>nul
exit /b 0

:probe_hash_url
rem Only reached from the refusal path: report WHY the hash could not be fetched, so a
rem bare "no SHA256" does not hide a wrong URL / an empty mirror (HTTP 404).
set "CODE="
for /f "usebackq delims=" %%C in (`curl -sSL --connect-timeout 8 -o NUL -w "%%{http_code}" "%~1/%BINARY_NAME%.sha256" 2^>nul`) do set "CODE=%%C"
if not defined CODE set "CODE=000"
if "%CODE%"=="404" (
    echo   - %~1/%BINARY_NAME%.sha256 -^> HTTP 404: path/branch wrong, or the mirror has no content on this branch yet
) else (
    echo   - %~1/%BINARY_NAME%.sha256 -^> HTTP %CODE%
)
exit /b 0

:download_from_list
rem Audit DP-02: retry loop must NOT use goto inside the for-body; use a subroutine per URL.
setlocal
for %%B in (%BASE_URL_LIST%) do (
    echo   - Trying: %%B/%BINARY_NAME%
    call :try_one_url "%%B"
    if not errorlevel 1 (
        endlocal
        exit /b 0
    )
)
endlocal
echo Download failed on all mirrors.
exit /b 1

:try_one_url
setlocal
set "URL=%~1"
set "TRY=0"
:retry_one
set /a TRY+=1
curl -fL -# --connect-timeout 8 --retry 2 --retry-delay 1 --speed-time 20 --speed-limit 10240 -o "%BINARY_PATH%" "%URL%/%BINARY_NAME%"
if not errorlevel 1 exit /b 0
if %TRY% lss 3 (
    timeout /t 1 >nul
    goto :retry_one
)
endlocal
exit /b 1
