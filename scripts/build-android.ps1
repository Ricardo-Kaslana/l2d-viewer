<#
.SYNOPSIS
    Android 本地一键构建脚本（交叉编译 .so -> cp jniLibs -> flutter build apk）。

.DESCRIPTION
    封装 docs/DEBUGGING.md 的 Android 构建命令为一个本地命令。
    与 .github/workflows/ci.yml 的 android-build job 共用同一逻辑，
    消除"本地手工 cp vs CI 不 cp"的双轨。

    默认行为：
    1. 校验 ANDROID_NDK_HOME 已设置（或通过 -NdkHome 传入）
    2. cargo build -p mocari_host --target aarch64-linux-android --release
    3. dart run tool/stage_android_libs.dart 落位 .so
       并用 SHA-256 校验两边一致
    4. cd app && flutter build apk (默认 --debug)
    5. 若 -Install 且存在真机，adb install -r

.PARAMETER Release
    构建 release APK（默认 debug）。

.PARAMETER NoBuild
    跳过 cargo 交叉编译与 cp 步骤，仅 flutter build apk。
    用于 .so 已是最新、只想重打 APK 的场景。

.PARAMETER Install
    构建完成后 adb install -r 到真机。
    若 -Device 未指定且存在多台设备，会报错。

.PARAMETER Device
    指定 adb 设备序列号（adb devices 输出）。
    仅与 -Install 配合使用。

.PARAMETER Logcat
    安装并 am start 后，自动抓取 §6.4 的 logcat 验证序列：
    install_android / attach_surface / frame_loop: render_to_surface OK / frameEvent
    需要 -Install 一起使用（仅 -Logcat 不安装时无意义）。

.PARAMETER NdkHome
    显式传入 NDK 根目录，优先级高于 $env:ANDROID_NDK_HOME。

.PARAMETER SkipNdkCheck
    跳过 NDK 环境检查（用于已配置好交叉编译链的场景）。

.EXAMPLE
    .\scripts\build-android.ps1
    默认 debug 构建，不安装。

.EXAMPLE
    .\scripts\build-android.ps1 -Release -Install -Device JNYAL1012345
    release 构建 + 安装到指定设备。

.EXAMPLE
    .\scripts\build-android.ps1 -NoBuild
    .so 已最新，仅重打 debug APK。
#>
[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$NoBuild,
    [switch]$Install,
    [string]$Device,
    [switch]$Logcat,
    [string]$NdkHome,
    [switch]$SkipNdkCheck
)

$ErrorActionPreference = 'Stop'
$env:PUB_HOSTED_URL = 'https://pub.dev'

# --- 仓库根定位 --------------------------------------------------------------
# 脚本在 scripts/ 下，仓库根 = 脚本目录的父目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir '..')
Write-Host "[build-android] repo root: $RepoRoot"

# --- NDK 环境检查 ------------------------------------------------------------
if (-not $SkipNdkCheck) {
    $EffectiveNdk = if ($NdkHome) { $NdkHome } else { $env:ANDROID_NDK_HOME }
    if (-not $EffectiveNdk) {
        Write-Error @"
ANDROID_NDK_HOME 未设置，且未通过 -NdkHome 传入。
请设置环境变量：
    `$env:ANDROID_NDK_HOME = "<ndk-root>"
或使用 -NdkHome <path> 参数。
若已配置好交叉编译链，可用 -SkipNdkCheck 跳过此检查。
"@
        exit 1
    }
    if (-not (Test-Path $EffectiveNdk)) {
        Write-Error "NDK 路径不存在: $EffectiveNdk"
        exit 1
    }

    $NdkHostTag = if ($env:OS -eq 'Windows_NT') {
        'windows-x86_64'
    } elseif ($IsMacOS) {
        'darwin-x86_64'
    } else {
        'linux-x86_64'
    }
    $NdkBin = Join-Path $EffectiveNdk "toolchains\llvm\prebuilt\$NdkHostTag\bin"
    if (-not (Test-Path $NdkBin)) {
        Write-Error "NDK bin 目录不存在: $NdkBin"
        exit 1
    }
    $LinkerName = if ($env:OS -eq 'Windows_NT') {
        'aarch64-linux-android21-clang.cmd'
    } else {
        'aarch64-linux-android21-clang'
    }
    $Linker = Join-Path $NdkBin $LinkerName
    if (-not (Test-Path $Linker)) {
        Write-Error "NDK linker 不存在: $Linker"
        exit 1
    }
    $env:PATH = "$NdkBin;$env:PATH"
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $Linker
    $env:ANDROID_NDK_HOME = $EffectiveNdk
    Write-Host "[build-android] ANDROID_NDK_HOME = $EffectiveNdk"
    Write-Host "[build-android] linker = $Linker"
}

# --- 1. cargo 交叉编译 -------------------------------------------------------
if (-not $NoBuild) {
    Write-Host "`n=== [1/4] cargo cross-compile (aarch64-linux-android, release) ===" -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        & rustup target add aarch64-linux-android
        if ($LASTEXITCODE -ne 0) {
            Write-Error "rustup target add 失败 (exit $LASTEXITCODE)"
            exit 1
        }
        & cargo build -p mocari_host --target aarch64-linux-android --release
        if ($LASTEXITCODE -ne 0) {
            Write-Error "cargo build 失败 (exit $LASTEXITCODE)"
            exit 1
        }
    }
    finally { Pop-Location }

    # --- 2. stage .so into jniLibs + SHA-256 verify ---------------------------
    Write-Host "`n=== [2/4] stage .so into jniLibs + SHA-256 verify ===" -ForegroundColor Cyan
    Push-Location (Join-Path $RepoRoot 'app')
    try {
        & flutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) {
            Write-Error "flutter pub get 失败 (exit $LASTEXITCODE)"
            exit 1
        }
        & dart run tool/stage_android_libs.dart
        if ($LASTEXITCODE -ne 0) {
            Write-Error "stage_android_libs.dart 失败 (exit $LASTEXITCODE)"
            exit 1
        }
    }
    finally { Pop-Location }
}
else {
    Write-Host "`n=== [1-2/4] skipped (-NoBuild) ===" -ForegroundColor Yellow
}

# --- 3. flutter build apk ----------------------------------------------------
Write-Host "`n=== [3/4] flutter build apk ===" -ForegroundColor Cyan
$ApkMode = if ($Release) { 'release' } else { 'debug' }
Write-Host "[build-android] APK mode: $ApkMode"

Push-Location (Join-Path $RepoRoot 'app')
try {
    if ($Release) {
        & flutter build apk --release --target-platform android-arm64
    }
    else {
        & flutter build apk --debug --target-platform android-arm64
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "flutter build apk 失败 (exit $LASTEXITCODE)"
        exit 1
    }
}
finally { Pop-Location }

# --- 4. 可选: adb install ----------------------------------------------------
$ApkPath = Join-Path $RepoRoot "app\build\app\outputs\flutter-apk\app-$ApkMode.apk"
if (-not (Test-Path $ApkPath)) {
    # 某些 Flutter 版本输出 app-arm64-v8a.apk 等，做一次通配兜底
    $ApkWildcards = @(
        "app-$ApkMode.apk",
        "app-$ApkMode-arm64-v8a.apk",
        "app-arm64-v8a-$ApkMode.apk"
    ) | ForEach-Object { Join-Path $RepoRoot "app\build\app\outputs\flutter-apk\$_" }
    $ApkPath = $ApkWildcards | Where-Object { Test-Path $_ } | Select-Object -First 1
}

if (-not $ApkPath -or -not (Test-Path $ApkPath)) {
    Write-Warning "未找到 APK 输出，跳过 install 步骤。"
    Write-Host "[build-android] DONE (no APK found for install)" -ForegroundColor Green
    exit 0
}

Write-Host "[build-android] APK: $ApkPath"

if ($Install) {
    Write-Host "`n=== [4/4] adb install -r ===" -ForegroundColor Cyan

    # 校验 adb 可用
    $AdbCmd = Get-Command adb -ErrorAction SilentlyContinue
    if (-not $AdbCmd) {
        Write-Warning "adb 未找到（未在 PATH 或 SDK platform-tools 未装），跳过 install。"
        Write-Host "[build-android] DONE (adb missing)" -ForegroundColor Green
        exit 0
    }

    $DevicesRaw = & adb devices
    $Devices = $DevicesRaw | Where-Object { $_ -match '^\S+\s+device$' } |
               ForEach-Object { ($_ -split '\s+')[0] }

    if ($Devices.Count -eq 0) {
        Write-Warning "adb devices 未发现真机，跳过 install。请确认 USB 调试已开启。"
        Write-Host "[build-android] DONE (no device)" -ForegroundColor Green
        exit 0
    }

    $TargetDevice = if ($Device) { $Device } else { $Devices[0] }

    if ($Device -and ($Devices -notcontains $Device)) {
        Write-Error "指定的 -Device $Device 不在 adb devices 列表中: $($Devices -join ', ')"
        exit 1
    }

    if ($Devices.Count -gt 1 -and -not $Device) {
        Write-Warning "发现多台设备 ($($Devices -join ', '))，未指定 -Device，将安装到第一台: $TargetDevice"
    }

    Write-Host "[build-android] installing to $TargetDevice ..."
    & adb -s $TargetDevice install -r $ApkPath
    if ($LASTEXITCODE -ne 0) {
        Write-Error "adb install 失败 (exit $LASTEXITCODE)"
        exit 1
    }

    # Clear the logcat buffer BEFORE launching the app so a previous
    # run's matching lines are not counted toward this build's coverage
    # report. Clearing after `am start` (the old order) wiped this
    # run's own startup sequence — install_android / attach_surface /
    # render_to_surface OK all fire within the first seconds — making
    # the coverage check report 0% even on a healthy build.
    if ($Logcat) {
        & adb -s $TargetDevice logcat -c | Out-Null
    }

    Write-Host "[build-android] starting io.github.dev.live2dviewer/.MainActivity ..."
    & adb -s $TargetDevice shell am start -n io.github.dev.live2dviewer/.MainActivity | Out-Null

    # --- 可选: -Logcat 自动抓取 §6.4 的渲染管线验证序列 -------------------
    if ($Logcat) {
        Write-Host "`n=== [4/4] logcat 渲染管线验证 ===" -ForegroundColor Cyan
        Write-Host "[build-android] 等待 3 秒让首帧渲染完成..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 3

        # §6.4 的 grep 模式：install_android / attach_surface / render_to_surface OK / frameEvent
        $LogcatRaw = & adb -s $TargetDevice logcat -d -s flutter:I,mocari_host:V 2>&1
        $ExpectedPatterns = @(
            'install_android',
            'attach_surface',
            'frame_loop: render_to_surface OK',
            'frameEvent'
        )

        Write-Host "`n----- logcat 关键行（§6.4 序列）-----" -ForegroundColor Cyan
        $MatchedPatterns = @()
        foreach ($line in $LogcatRaw) {
            foreach ($pat in $ExpectedPatterns) {
                if ($line -match $pat) {
                    Write-Host "  $line" -ForegroundColor Green
                    if ($MatchedPatterns -notcontains $pat) {
                        $MatchedPatterns += $pat
                    }
                    break
                }
            }
        }
        Write-Host "----- end logcat -----`n" -ForegroundColor Cyan

        # 报告覆盖率
        $Coverage = $MatchedPatterns.Count / $ExpectedPatterns.Count * 100
        Write-Host "[build-android] logcat 覆盖率: $($MatchedPatterns.Count)/$($ExpectedPatterns.Count) ($([math]::Round($Coverage, 1))%)"

        $Missing = $ExpectedPatterns | Where-Object { $MatchedPatterns -notcontains $_ }
        if ($Missing.Count -gt 0) {
            Write-Warning "未匹配的关键模式: $($Missing -join ', ')"
            Write-Host "[build-android] 可能原因:" -ForegroundColor Yellow
            Write-Host "  - 首帧尚未渲染（增大 Start-Sleep 或手动重抓）" -ForegroundColor Yellow
            Write-Host "  - install_android_surface 内未清 Stage（见 docs/postmortem/2026-07-23-android-stage-stale-after-device-swap.md）" -ForegroundColor Yellow
            Write-Host "  - 帧循环 worker 拿到绑定在已释放设备上的资源（Vulkan 静默不出画面）" -ForegroundColor Yellow
            Write-Host "`n[build-android] 手动重抓命令:" -ForegroundColor DarkGray
            Write-Host "  adb -s $TargetDevice logcat -d -s flutter:I,mocari_host:V | " -ForegroundColor DarkGray
            Write-Host "      grep -iE 'install_android|attach_surface|frame_loop: render_to_surface OK|frameEvent'" -ForegroundColor DarkGray
        }
        else {
            Write-Host "[build-android] logcat 验证通过：所有关键模式均匹配。" -ForegroundColor Green
        }
    }
    else {
        Write-Host "`n[build-android] 提示: 验证渲染管线用 logcat:" -ForegroundColor DarkGray
        Write-Host "  adb -s $TargetDevice logcat -d -s flutter:I,mocari_host:V | " -ForegroundColor DarkGray
        Write-Host "      grep -iE 'install_android|attach_surface|frame_loop: render_to_surface OK|frameEvent'" -ForegroundColor DarkGray
        Write-Host "  或重新运行加 -Logcat 自动验证" -ForegroundColor DarkGray
    }
}
else {
    Write-Host "`n=== [4/4] skipped (no -Install) ===" -ForegroundColor Yellow
    Write-Host "[build-android] APK 已就绪: $ApkPath"
    Write-Host "[build-android] 若要安装到真机: 重新运行并加 -Install"
}

Write-Host "`n[build-android] DONE" -ForegroundColor Green
