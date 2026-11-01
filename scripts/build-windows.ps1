<#
.SYNOPSIS
    Windows 本地一键构建/运行脚本。

.DESCRIPTION
    封装 docs/DEBUGGING.md 的 Windows 构建/运行命令为一个本地命令。
    解决"改了 Rust 但 flutter run 仍是旧行为"的最常见陷阱（旧 exe 加载旧 DLL）。

    默认行为（-Run）：
    1. 杀掉残留的 live2d_viewer.exe 进程（否则 DLL/exe 被占用，拷贝/链接失败）
    2. 删除 build/windows/x64/runner/Debug/live2d_viewer.exe（强制重链）
    3. cd app && flutter run -d windows

    若 -Build（而非 -Run）：
    3'. cd app && flutter build windows --debug（或 --release）

    若 -NativeOnly：
    1''. 跳过杀进程/删 exe，直接 cmake --build build/windows/x64 --config Debug --target live2d_viewer
         用于改了 texture_handler.{h,cpp} 后只想重编 native 的场景

.PARAMETER Run
    flutter run -d windows（默认行为；与 -Build 互斥）。

.PARAMETER Build
    flutter build windows（与 -Run 互斥）。

.PARAMETER Release
    构建 release（默认 debug）。仅与 -Build 配合有意义；-Run 时忽略。

.PARAMETER NativeOnly
    只重编 native（跳过 flutter run/build）。用于改 texture_handler.* 后的快速重编。
    与 -Run / -Build 互斥。

.PARAMETER NoClean
    跳过"杀进程 + 删旧 exe"步骤。用于确认无残留进程、想加速重跑的场景。

.PARAMETER DeviceId
    传递给 flutter run -d 的设备 id（如 windows、windows-x64）。
    默认不传 -d，让 flutter 自动选。

.EXAMPLE
    .\scripts\build-windows.ps1
    默认 -Run：杀进程 -> 删 exe -> flutter run -d windows

.EXAMPLE
    .\scripts\build-windows.ps1 -Build -Release
    构建 release exe（不运行）

.EXAMPLE
    .\scripts\build-windows.ps1 -NativeOnly
    只 cmake --build native target，用于改 texture_handler.cpp 后的快速重编

.EXAMPLE
    .\scripts\build-windows.ps1 -NoClean
    不杀进程/不删 exe，直接 flutter run（用于确认无残留时的加速重跑）
#>
[CmdletBinding()]
param(
    [switch]$Run,
    [switch]$Build,
    [switch]$Release,
    [switch]$NativeOnly,
    [switch]$NoClean,
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'
$env:PUB_HOSTED_URL = 'https://pub.dev'

# 互斥校验
$ModeCount = (@($Run, $Build, $NativeOnly) | Where-Object { $_ }).Count
if ($ModeCount -gt 1) {
    Write-Error "-Run / -Build / -NativeOnly 互斥，最多选一个。"
    exit 1
}
# 默认 -Run
if ($ModeCount -eq 0) { $Run = $true }

# --- 仓库根定位 --------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir '..')
$AppDir = Join-Path $RepoRoot 'app'
Write-Host "[build-windows] repo root: $RepoRoot"

# --- 1. 杀进程 + 删旧 exe（除非 -NoClean 或 -NativeOnly）---------------------
if (-not $NoClean -and -not $NativeOnly) {
    Write-Host "`n=== [1/3] kill stale live2d_viewer.exe + remove old exe ===" -ForegroundColor Cyan

    # 杀进程（不存在时 SilentlyContinue 忽略）
    $procs = Get-Process live2d_viewer -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Host "[build-windows] stopping live2d_viewer.exe (pid: $($procs.Id -join ','))"
        $procs | Stop-Process -Force
        Start-Sleep -Milliseconds 500  # 给 OS 释放文件句柄的时间
    }
    else {
        Write-Host "[build-windows] no stale live2d_viewer.exe process"
    }

    # 删旧 exe（不存在时 SilentlyContinue 忽略）
    $OldExe = Join-Path $AppDir 'build\windows\x64\runner\Debug\live2d_viewer.exe'
    if (Test-Path $OldExe) {
        Remove-Item $OldExe -Force -ErrorAction SilentlyContinue
        Write-Host "[build-windows] removed: $OldExe"
    }
    else {
        Write-Host "[build-windows] no old exe to remove: $OldExe"
    }
}
else {
    $skipped = if ($NativeOnly) { '(-NativeOnly)' } else { '(-NoClean)' }
    Write-Host "`n=== [1/3] skipped $skipped ===" -ForegroundColor Yellow
}

# --- 2. 执行构建/运行 --------------------------------------------------------
if ($NativeOnly) {
    Write-Host "`n=== [2/3] cmake --build native target ===" -ForegroundColor Cyan
    Push-Location $AppDir
    try {
        & cmake --build build/windows/x64 --config Debug --target live2d_viewer
        if ($LASTEXITCODE -ne 0) {
            Write-Error "cmake --build 失败 (exit $LASTEXITCODE)"
            exit 1
        }
    }
    finally { Pop-Location }
}
elseif ($Build) {
    Write-Host "`n=== [2/3] flutter build windows ===" -ForegroundColor Cyan
    Push-Location $AppDir
    try {
        if ($Release) {
            & flutter build windows --release
        }
        else {
            & flutter build windows --debug
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "flutter build windows 失败 (exit $LASTEXITCODE)"
            exit 1
        }
    }
    finally { Pop-Location }
}
else {  # -Run
    Write-Host "`n=== [2/3] flutter run -d windows ===" -ForegroundColor Cyan
    Push-Location $AppDir
    try {
        if ($DeviceId) {
            & flutter run -d $DeviceId
        }
        else {
            & flutter run -d windows
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Error "flutter run 失败 (exit $LASTEXITCODE)"
            exit 1
        }
    }
    finally { Pop-Location }
}

# --- 3. 提示 -----------------------------------------------------------------
Write-Host "`n=== [3/3] DONE ===" -ForegroundColor Green
if ($Build) {
    $OutDir = if ($Release) {
        Join-Path $AppDir 'build\windows\x64\runner\Release'
    }
    else {
        Join-Path $AppDir 'build\windows\x64\runner\Debug'
    }
    Write-Host "[build-windows] output: $OutDir"
    Write-Host "[build-windows] exe: $(Join-Path $OutDir 'live2d_viewer.exe')"
}
elseif ($NativeOnly) {
    Write-Host "[build-windows] native target rebuilt"
    Write-Host "[build-windows] 后续用 .\scripts\build-windows.ps1 -Run 启动"
}
else {
    Write-Host "[build-windows] flutter run 已退出"
}

Write-Host "`n[build-windows] 提示: stderr 期望看到 DxgiSharedHandle 路径日志:" -ForegroundColor DarkGray
Write-Host "  [live2d/texture] SharedOffscreenTexture: D3D12 adapter LUID = ..." -ForegroundColor DarkGray
Write-Host "  [live2d/texture] register: sending native_handle=0x... (WxH)" -ForegroundColor DarkGray
Write-Host "  [live2d/texture] register: returned texture_id=<n>" -ForegroundColor DarkGray
