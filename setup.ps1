<#
.SYNOPSIS
    One-shot environment setup for building Patina (pure-Rust UEFI DXE Core) QEMU firmware on Windows.

.DESCRIPTION
    Run once from a normal (non-admin) PowerShell. It is idempotent: re-running only fills in what is missing.

    What it does, in order:
      1. Checks Git, Python 3.10+, Visual Studio 2022 Build Tools (C++ workload) and rustup;
         installs missing ones through winget.
      2. Downloads the portable LLVM release (default 21.1.8) into .\tools\LLVM21 (no installer, no admin).
      3. Clones patina-qemu and patina-dxe-core-qemu next to this script (skipped if already present).
      4. Installs the Rust toolchain pinned by patina-dxe-core-qemu (rust-toolchain.toml) incl. UEFI targets,
         and the pinned cargo-make version.
      5. Installs edk2-pytools (pip-requirements.txt of patina-qemu).
      6. Runs stuart_setup / stuart_update for QemuQ35Pkg: git submodules, QEMU for Windows, NASM, iasl,
         EDK II BaseTools binaries, prebuilt Patina DXE Core and other external dependencies.
      7. With -DebugTools: installs WinDbg (winget) and the UEFI WinDbg extension (uefiext) from
         microsoft/uefi_debug_tools, which together give source-level debugging of the Rust DXE Core
         (see README.md, "Debugging").

    After it finishes, run .\build_q35.ps1 (see README.md).

.PARAMETER LlvmVersion
    Portable LLVM release to download. The repo recommends LLVM >= 21; LLVM 23 trips new -Werror warnings.
.PARAMETER PatinaQemuUrl
    Git URL of patina-qemu.
.PARAMETER DxeCoreQemuUrl
    Git URL of patina-dxe-core-qemu.
.PARAMETER NoInstall
    Only check prerequisites and report; never call winget.
.PARAMETER DebugTools
    Also install the debugging software: WinDbg (winget id Microsoft.WinDbg, ships the EXDi GDB transport) and the
    UEFI WinDbg extension (UefiExt_x64.zip from microsoft/uefi_debug_tools) into %LOCALAPPDATA%\Dbg\EngineExtensions.
.PARAMETER UefiExtVersion
    Release tag of microsoft/uefi_debug_tools to install (for example v0.8.1). Default: the latest release on GitHub.

.EXAMPLE
    .\setup.ps1
.EXAMPLE
    .\setup.ps1 -LlvmVersion 21.1.8 -NoInstall
.EXAMPLE
    .\setup.ps1 -DebugTools
#>
[CmdletBinding()]
param(
    [string]$LlvmVersion = "21.1.8",
    [string]$PatinaQemuUrl = "https://github.com/OpenDevicePartnership/patina-qemu.git",
    [string]$DxeCoreQemuUrl = "https://github.com/OpenDevicePartnership/patina-dxe-core-qemu.git",
    [switch]$NoInstall,
    [switch]$DebugTools,
    [string]$UefiExtVersion = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = $PSScriptRoot
$toolsDir = Join-Path $root "tools"
$llvmDir = Join-Path $toolsDir "LLVM21"
$patinaQemu = Join-Path $root "patina-qemu"
$dxeCoreQemu = Join-Path $root "patina-dxe-core-qemu"
$platformBuild = "Platforms/QemuQ35Pkg/PlatformBuild.py"

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "    [xx] $msg" -ForegroundColor Red; throw $msg }

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $user = [Environment]::GetEnvironmentVariable("PATH", "User")
    $env:PATH = $machine + ";" + $user + ";" + $env:PATH
}

function Have($cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Native tools (git, winget, curl, pip, stuart_*) print progress on stderr. When this script's output is redirected
# ("> setup.log 2>&1"), Windows PowerShell 5.1 turns each stderr line into an error record, and with "Stop" that
# aborts the script at the first such line. Native commands therefore run with "Continue" and their stderr merged
# into stdout as plain text; callers check $LASTEXITCODE.
function Invoke-Native($exe, [string[]]$argv) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $exe @argv 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
        }
    } finally { $ErrorActionPreference = $prev }
}

function Winget-Install($id, $what) {
    if ($NoInstall) { Fail "$what is missing (re-run without -NoInstall, or install it manually)" }
    if (-not (Have "winget")) { Fail "$what is missing and winget is not available. Install it manually." }
    Write-Host "    installing $what via winget ($id) ..."
    Invoke-Native "winget" @("install", "--id", $id, "-e", "--accept-source-agreements", "--accept-package-agreements", "--disable-interactivity")
    if ($LASTEXITCODE -ne 0) { Fail "winget install $id failed with exit code $LASTEXITCODE" }
    Refresh-Path
}

function Run($exe, [string[]]$argv, $cwd = $null) {
    Write-Host "    > $exe $($argv -join ' ')" -ForegroundColor DarkGray
    if ($cwd) { Push-Location $cwd }
    try {
        Invoke-Native $exe $argv
        if ($LASTEXITCODE -ne 0) { Fail "$exe exited with code $LASTEXITCODE" }
    } finally { if ($cwd) { Pop-Location } }
}

function Toml-Value($file, $key) {
    $m = Get-Content $file | Select-String ("^" + [regex]::Escape($key) + '\s*=\s*"([^"]+)"')
    if (-not $m) { Fail "key '$key' not found in $file" }
    return $m.Matches[0].Groups[1].Value
}

# --------------------------------------------------------------------------------------------------
Step "Git"
if (-not (Have "git")) { Winget-Install "Git.Git" "Git" }
Ok (git --version)
# MU_BASECORE contains paths > 260 chars. GIT_CONFIG_PARAMETERS is honoured by every git process started
# from here on (including the submodule clones that stuart_setup runs), without touching the user's config.
$env:GIT_CONFIG_PARAMETERS = "'core.longpaths=true'"
if ($root.Length -gt 60) {
    Warn "This directory path is $($root.Length) characters long; a short path such as C:\src\patina is safer on Windows."
}
$lp = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name LongPathsEnabled -ErrorAction SilentlyContinue
if (-not ($lp -and $lp.LongPathsEnabled -eq 1)) {
    Warn "Windows long paths are disabled (HKLM\...\FileSystem\LongPathsEnabled). Git is told to cope; other tools may not."
}

# --------------------------------------------------------------------------------------------------
Step "Python 3.10+"
$pyOk = $false
if (Have "python") {
    $v = (& python -c "import sys; print('%d.%d' % sys.version_info[:2])") 2>$null
    if ($v -and ([version]$v -ge [version]"3.10")) { $pyOk = $true; Ok "python $v" }
}
if (-not $pyOk) {
    Winget-Install "Python.Python.3.12" "Python 3.12"
    if (-not (Have "python")) { Fail "python still not on PATH; open a new terminal and re-run" }
    Ok (python --version)
}

# --------------------------------------------------------------------------------------------------
Step "Visual Studio 2022 Build Tools (MSVC C++ toolset: nmake and vcvars are used by the CLANGPDB build)"
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vsPath = $null
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -latest 2>$null
}
if ($vsPath) {
    Ok "found $vsPath"
} else {
    Warn "No Visual Studio 2022 with the C++ toolset found."
    if ($NoInstall) { Fail "Install 'Visual Studio 2022 Build Tools' with the 'Desktop development with C++' workload." }
    if (-not (Have "winget")) { Fail "winget not available; install Build Tools 2022 (C++ workload) manually." }
    Warn "Installing Build Tools 2022 with the VC workload via winget (UAC prompt, several minutes)."
    Invoke-Native "winget" @("install", "--id", "Microsoft.VisualStudio.2022.BuildTools", "-e", "--accept-source-agreements",
        "--accept-package-agreements", "--override", "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended")
    if ($LASTEXITCODE -ne 0) { Fail "Build Tools install failed ($LASTEXITCODE). Install it manually with the C++ workload." }
    Ok "Build Tools installed"
}

# --------------------------------------------------------------------------------------------------
Step "rustup"
if (-not (Have "rustup")) {
    Winget-Install "Rustlang.Rustup" "rustup"
    if (-not (Have "rustup")) { Fail "rustup still not on PATH; open a new terminal and re-run" }
}
Ok ((rustup --version 2>&1 | Select-Object -First 1))

# --------------------------------------------------------------------------------------------------
Step "Portable LLVM $LlvmVersion -> $llvmDir"
$clang = Join-Path $llvmDir "bin\clang.exe"
if (Test-Path $clang) {
    Ok ((& $clang --version | Select-Object -First 1))
} else {
    New-Item -ItemType Directory -Force $toolsDir | Out-Null
    $asset = "clang+llvm-$LlvmVersion-x86_64-pc-windows-msvc.tar.xz"
    $url = "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LlvmVersion/$asset"
    $archive = Join-Path $toolsDir $asset
    if (-not (Test-Path $archive)) {
        Write-Host "    downloading $url (about 1 GB) ..."
        Invoke-Native "curl.exe" @("-L", "--fail", "--retry", "3", "-o", $archive, $url)
        if ($LASTEXITCODE -ne 0) { Fail "download failed" }
    }
    New-Item -ItemType Directory -Force $llvmDir | Out-Null
    Write-Host "    extracting ..."
    Invoke-Native "tar.exe" @("-xf", $archive, "-C", $llvmDir, "--strip-components=1")
    if ($LASTEXITCODE -ne 0) {
        $gitTar = "C:\Program Files\Git\usr\bin\tar.exe"
        if (-not (Test-Path $gitTar)) { Fail "tar extraction failed and Git's tar was not found" }
        Write-Host "    system tar failed, retrying with Git's tar ..."
        Invoke-Native $gitTar @("-xf", $archive, "-C", $llvmDir, "--strip-components=1")
        if ($LASTEXITCODE -ne 0) { Fail "tar extraction failed" }
    }
    if (-not (Test-Path $clang)) { Fail "clang.exe not found after extraction" }
    Remove-Item $archive -Force
    Ok ((& $clang --version | Select-Object -First 1))
}

# --------------------------------------------------------------------------------------------------
Step "Clone upstream repositories"
if (Test-Path (Join-Path $patinaQemu ".git")) { Ok "patina-qemu already cloned" }
else { Run "git" @("clone", $PatinaQemuUrl, $patinaQemu) }
if (Test-Path (Join-Path $dxeCoreQemu ".git")) { Ok "patina-dxe-core-qemu already cloned" }
else { Run "git" @("clone", $DxeCoreQemuUrl, $dxeCoreQemu) }

# --------------------------------------------------------------------------------------------------
Step "Rust toolchain pinned by patina-dxe-core-qemu/rust-toolchain.toml (channel, UEFI targets, components)"
$toolchainToml = Join-Path $dxeCoreQemu "rust-toolchain.toml"
$channel = Toml-Value $toolchainToml "channel"
# `rustup show` inside the repo installs the pinned channel plus its targets and components.
Run "rustup" @("show", "active-toolchain") $dxeCoreQemu
Ok ((& rustc "+$channel" --version))

# --------------------------------------------------------------------------------------------------
Step "cargo-make (version pinned in rust-toolchain.toml [tools])"
$cmVer = Toml-Value $toolchainToml "cargo-make"
$haveCm = $null
if (Have "cargo-make") { $haveCm = (& cargo make --version 2>$null) }
if ($haveCm -and ($haveCm -match [regex]::Escape($cmVer))) {
    Ok $haveCm
} else {
    # Run from $root (no rust-toolchain.toml there) so the default stable toolchain builds it.
    Run "cargo" @("install", "--locked", "cargo-make@$cmVer") $root
    Ok (& cargo make --version)
}

# --------------------------------------------------------------------------------------------------
Step "edk2-pytools (pip)"
Run "python" @("-m", "pip", "install", "--upgrade", "-r", (Join-Path $patinaQemu "pip-requirements.txt"))
Ok (& python -c "import edk2toolext, edk2toollib; print('edk2-pytool-extensions ok')")

# --------------------------------------------------------------------------------------------------
# The stuart_* console scripts live in Python's Scripts dir, which is often not on PATH. Resolve them
# explicitly. (Note: `python -m edk2toolext.invocables.edk2_setup` is a silent no-op, the modules have
# no __main__ guard.)
$pyScripts = (& python -c "import sysconfig; print(sysconfig.get_path('scripts'))").Trim()
function Stuart($name) {
    $exe = Join-Path $pyScripts "$name.exe"
    if (Test-Path $exe) { return $exe }
    if (Have $name) { return $name }
    Fail "$name not found in $pyScripts or on PATH (edk2-pytool-extensions install failed?)"
}

Step "stuart_setup (git submodules required by QemuQ35Pkg)"
Run (Stuart "stuart_setup") @("-c", $platformBuild) $patinaQemu
Ok "stuart_setup finished"

Step "stuart_update (QEMU, NASM, iasl, BaseTools, prebuilt Patina DXE Core, ...)"
Run (Stuart "stuart_update") @("-c", $platformBuild) $patinaQemu
Ok "stuart_update finished"

# --------------------------------------------------------------------------------------------------
if ($DebugTools) {
    Step "WinDbg (EXDi transport: WinDbg speaks the GDB remote protocol to the Patina software debugger)"
    $windbg = Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $windbg) {
        Winget-Install "Microsoft.WinDbg" "WinDbg"
        $windbg = Get-AppxPackage -Name Microsoft.WinDbg -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($windbg) {
        Ok "WinDbg $($windbg.Version) at $($windbg.InstallLocation)"
        $exdi = Join-Path $windbg.InstallLocation "amd64\ExdiGdbSrv.dll"
        if (Test-Path $exdi) { Ok "ExdiGdbSrv.dll present" }
        else { Warn "ExdiGdbSrv.dll not found under $($windbg.InstallLocation); EXDi debugging needs it" }
    } else {
        Warn "WinDbg package not visible to this session; start WinDbg once from the Start menu and re-run if needed."
    }

    $extDir = Join-Path $env:LOCALAPPDATA "Dbg\EngineExtensions"
    Step "UEFI WinDbg extension (uefiext) -> $extDir"
    $tag = $UefiExtVersion
    if (-not $tag) {
        $api = "https://api.github.com/repos/microsoft/uefi_debug_tools/releases/latest"
        $json = & curl.exe -sL --fail --retry 3 $api
        if ($LASTEXITCODE -eq 0 -and $json) { $tag = ($json | ConvertFrom-Json).tag_name }
        if (-not $tag) { $tag = "v0.8.1"; Warn "could not query GitHub for the latest release, using $tag" }
    }
    $marker = Join-Path $extDir "uefiext.version"
    $installed = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { "" }
    if (($installed -eq $tag) -and (Test-Path (Join-Path $extDir "uefiext.dll"))) {
        Ok "uefiext $tag already installed"
    } else {
        $url = "https://github.com/microsoft/uefi_debug_tools/releases/download/$tag/UefiExt_x64.zip"
        $zip = Join-Path $toolsDir "UefiExt_x64_$tag.zip"
        New-Item -ItemType Directory -Force $toolsDir, $extDir | Out-Null
        Write-Host "    downloading $url ..."
        Invoke-Native "curl.exe" @("-L", "--fail", "--retry", "3", "-o", $zip, $url)
        if ($LASTEXITCODE -ne 0) { Fail "download failed (check the tag with -UefiExtVersion)" }
        # The zip holds uefiext.dll and EfiSymComposition.dll at its root; WinDbg loads extensions from this directory.
        Expand-Archive -Path $zip -DestinationPath $extDir -Force
        if (-not (Test-Path (Join-Path $extDir "uefiext.dll"))) { Fail "uefiext.dll not found after extraction" }
        Set-Content -Path $marker -Value $tag -Encoding ascii
        Remove-Item $zip -Force
        Ok "uefiext $tag installed ($((Get-ChildItem $extDir -Filter *.dll).Name -join ', '))"
    }
}

# --------------------------------------------------------------------------------------------------
Step "Done"
Write-Host @"
    Environment is ready. Next:

      .\build_q35.ps1                  build QemuQ35Pkg firmware with the prebuilt Patina DXE Core
      .\build_q35.ps1 -LocalCore -Run  build the Rust DXE Core from source, build firmware, run QEMU
      .\build_q35.ps1 -RunOnly         just run QEMU with the last build
      .\setup.ps1 -DebugTools          add WinDbg + uefiext for source-level debugging (README.md, "Debugging")

    See README.md for details.
"@
