<#
.SYNOPSIS
    Build and/or run the patina-qemu QemuQ35Pkg (x64) firmware with the Patina Rust DXE Core.

.DESCRIPTION
    Run .\setup.ps1 once before using this script. All toolchain environment variables needed by the
    CLANGPDB build (CLANG_BIN, CLANGPDB_DLL, PATH) are set here, so no vcvars / developer prompt is needed.

.PARAMETER LocalCore
    Build the Rust DXE Core from patina-dxe-core-qemu (cargo make q35[-release]) and use that .efi instead of
    the prebuilt one from the NuGet external dependency.
.PARAMETER EnableDebugger
    Build the Rust DXE Core with the enable_debugger cargo feature (implies -LocalCore): the Patina software debugger
    halts at an initial breakpoint and waits for WinDbg/GDB on COM1. Combine with -SerialPort to reach COM1 over TCP.
.PARAMETER Release
    Build the RELEASE target (both the Rust core and the firmware). Default is DEBUG.
.PARAMETER Run
    Launch QEMU with a display window after the build (--FlashRom).
.PARAMETER RunOnly
    Skip the build and launch QEMU with the last built firmware (--FlashOnly).
.PARAMETER Headless
    No display; firmware log goes to the console and the UEFI Shell runs "reset -s" so QEMU exits by itself.
.PARAMETER OsImage
    Path to a VHDX or QCOW2 OS image to boot instead of stopping at the UEFI Shell (PATH_TO_OS).
.PARAMETER SerialPort
    TCP port on which QEMU exposes COM1 (SERIAL_PORT). The Patina software debugger (patina_debugger) speaks the
    GDB remote protocol on COM1, so WinDbg (EXDi) or GDB connect to 127.0.0.1:<port>. Use together with
    -EnableDebugger; a core built without that feature never waits for a connection and COM1 stays silent.
.PARAMETER GdbServer
    TCP port for QEMU's own gdbstub (GDB_SERVER, "-gdb tcp:127.0.0.1:<port>"): hardware-level debugging that works
    even when the firmware itself is hung. Independent of -SerialPort; both can be used at once.
.PARAMETER DryRun
    Print the environment and the stuart_build command line without running anything.

.EXAMPLE
    .\build_q35.ps1
.EXAMPLE
    .\build_q35.ps1 -LocalCore -Run
.EXAMPLE
    .\build_q35.ps1 -RunOnly -OsImage D:\images\win11.vhdx
.EXAMPLE
    .\build_q35.ps1 -EnableDebugger -Run -SerialPort 50001 -GdbServer 5555
#>
[CmdletBinding()]
param(
    [switch]$LocalCore,
    [switch]$EnableDebugger,
    [switch]$Release,
    [switch]$Run,
    [switch]$RunOnly,
    [switch]$Headless,
    [string]$OsImage = "",
    [ValidateRange(1, 65535)][int]$SerialPort = 0,
    [ValidateRange(1, 65535)][int]$GdbServer = 0,
    [switch]$DryRun
)
$ErrorActionPreference = "Stop"
# cargo and stuart_build print progress on stderr. When the script's output is redirected (e.g. "> build.log 2>&1"),
# Windows PowerShell 5.1 turns each stderr line of a native command into an error record, and with "Stop" that aborts
# the script at the first "Compiling ..." line. Native commands are therefore run with "Continue" and their stderr is
# merged into stdout as plain text; callers check $LASTEXITCODE.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
        }
    } finally { $ErrorActionPreference = $prev }
}
$root = $PSScriptRoot
$patinaQemu = Join-Path $root "patina-qemu"
$dxeCoreQemu = Join-Path $root "patina-dxe-core-qemu"

foreach ($d in @($patinaQemu, $dxeCoreQemu)) {
    if (-not (Test-Path $d)) { throw "$d not found. Run .\setup.ps1 first." }
}

# Toolchain: LLVM 21 (repo recommends >= 21; LLVM 23 trips new -Werror warnings in this codebase).
$llvm = Join-Path $root "tools\LLVM21\bin"
if (-not (Test-Path (Join-Path $llvm "clang.exe"))) { throw "LLVM not found at $llvm. Run .\setup.ps1 first." }
$env:PATH = $llvm + ";" + $env:PATH
# tools_def uses ENV(CLANG_BIN)clang, so the value needs a trailing slash. Forward slashes avoid nmake quoting issues.
$env:CLANG_BIN = $llvm.Replace([string][char]92, "/") + "/"
# tools_def has *_CLANGPDB_*_*_DLL = ENV(CLANGPDB_DLL). If unset, AutoGen prepends "" to PATH and
# cmd.exe on Windows 11 then fails to resolve ANY command ("'GenSec' is not recognized").
$env:CLANGPDB_DLL = $llvm

if ($EnableDebugger -and -not $LocalCore) {
    Write-Host "-EnableDebugger implies -LocalCore (the prebuilt NuGet core has no debugger)"
    $LocalCore = $true
}
$target = if ($Release) { "RELEASE" } else { "DEBUG" }
$buildArgs = @("-c", "Platforms/QemuQ35Pkg/PlatformBuild.py", "TARGET=$target")

if ($LocalCore) {
    $task = if ($Release) { "q35-release" } else { "q35" }
    # enable_debugger implies build_debugger in Cargo.toml, so one feature is enough for both profiles.
    $cargoArgs = @("make", $task)
    if ($EnableDebugger) { $cargoArgs += @("--features", "enable_debugger") }
    Push-Location $dxeCoreQemu
    try {
        Write-Host ("cargo " + ($cargoArgs -join " ") + "  (in $dxeCoreQemu)")
        if (-not $DryRun) {
            Invoke-Native cargo $cargoArgs
            if ($LASTEXITCODE -ne 0) { throw "cargo $($cargoArgs -join ' ') failed" }
        }
    } finally { Pop-Location }
    # QemuQ35Pkg.fdf references $(DXE_CORE_PATH)/debug|release/qemu_q35_dxe_core.efi
    $buildArgs += "BLD_*_DXE_CORE_PATH=" + (Join-Path $dxeCoreQemu "target\x86_64-unknown-uefi")
}
if ($Headless) { $buildArgs += "QEMU_HEADLESS=TRUE"; $buildArgs += "SHUTDOWN_AFTER_RUN=TRUE" }
if ($OsImage) {
    if (-not (Test-Path $OsImage)) { throw "OS image not found: $OsImage" }
    $buildArgs += "PATH_TO_OS=" + (Resolve-Path $OsImage).Path
}
if ($SerialPort) { $buildArgs += "SERIAL_PORT=$SerialPort" }
if ($GdbServer) { $buildArgs += "GDB_SERVER=$GdbServer" }
if ($RunOnly) { $buildArgs += "--FlashOnly" } elseif ($Run) { $buildArgs += "--FlashRom" }

Push-Location $patinaQemu
try {
    Write-Host ("cwd: " + (Get-Location))
    Write-Host ("CLANG_BIN=" + $env:CLANG_BIN + "  CLANGPDB_DLL=" + $env:CLANGPDB_DLL)
    Write-Host ("stuart_build " + ($buildArgs -join " "))
    if ($DryRun) { exit 0 }
    # stuart_build lives in Python's Scripts dir, which is often not on PATH; resolve it explicitly.
    $pyScripts = (& python -c "import sysconfig; print(sysconfig.get_path('scripts'))").Trim()
    $stuart = Join-Path $pyScripts "stuart_build.exe"
    if (-not (Test-Path $stuart)) {
        if (Get-Command stuart_build -ErrorAction SilentlyContinue) { $stuart = "stuart_build" }
        else { throw "stuart_build not found in $pyScripts or on PATH. Run .\setup.ps1 first." }
    }
    Invoke-Native $stuart $buildArgs
    exit $LASTEXITCODE
} finally { Pop-Location }
