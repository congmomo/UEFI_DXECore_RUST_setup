<#
.SYNOPSIS
    Wire the hello_component example into patina-dxe-core-qemu (Q35), or remove it again.

.DESCRIPTION
    Edits two files in ..\..\patina-dxe-core-qemu, idempotently:
      - Cargo.toml            adds   hello_component = { path = "../examples/hello_component" }
      - bin/q35_dxe_core.rs   adds   add.config(...)  and two add.component(...) lines
    Then build and run with:  ..\..\build_q35.ps1 -LocalCore -Headless -Run
    and look for "[hello_component]" lines in the console output.

.PARAMETER Revert
    Remove the edits (restores the two files from git).
#>
[CmdletBinding()]
param([switch]$Revert)
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$repo = Resolve-Path (Join-Path $here "..\..\patina-dxe-core-qemu")
$cargoToml = Join-Path $repo "Cargo.toml"
$binRs = Join-Path $repo "bin\q35_dxe_core.rs"

# Set-Content -Encoding UTF8 writes a BOM on Windows PowerShell 5.1; keep the upstream files BOM-free.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
function Write-Utf8NoBom($path, $text) { [System.IO.File]::WriteAllText($path, $text, $utf8NoBom) }

if ($Revert) {
    # Cargo.lock gains a hello_component entry on the first build; restore it too.
    git -C $repo checkout -- Cargo.toml Cargo.lock bin/q35_dxe_core.rs
    Write-Host "reverted Cargo.toml, Cargo.lock and bin/q35_dxe_core.rs in $repo"
    exit 0
}

# --- Cargo.toml: add the path dependency right after the "[dependencies]" header -------------------
$toml = Get-Content $cargoToml -Raw
if ($toml -notmatch 'hello_component') {
    $dep = 'hello_component = { path = "../examples/hello_component" }'
    $toml = $toml -replace '(\[dependencies\]\r?\n)', ('$1' + $dep + "`r`n")
    Write-Utf8NoBom $cargoToml $toml
    Write-Host "added dependency to Cargo.toml"
} else { Write-Host "Cargo.toml already has hello_component" }

# --- bin/q35_dxe_core.rs: register config + components ----------------------------------------------
$rs = Get-Content $binRs -Raw
if ($rs -notmatch 'hello_component') {
    # 1) config: insert as the first statement of `fn configs(mut add: Add<Config>) {`
    $cfgLine = '        add.config(hello_component::GreetingConfig { exclamation_marks: 3 });'
    $rs = $rs -replace '(fn configs\(mut add: Add<Config>\) \{\r?\n)', ('$1' + $cfgLine + "`r`n")
    # 2) components: insert right after the AdvancedLoggerComponent line so logging is already up.
    $compLines = '        add.component(hello_component::GreetingConsumer); // registered first on purpose' + "`r`n" +
                 '        add.component(hello_component::HelloGreeter::new("Patina learner"));'
    $rs = $rs -replace '(add\.component\(AdvancedLoggerComponent::<Uart16550>::new\(&LOGGER\)\);\r?\n)', ('$1' + $compLines + "`r`n")
    if ($rs -notmatch 'GreetingConfig' -or $rs -notmatch 'HelloGreeter') {
        throw "could not find the insertion points in $binRs (upstream file changed?). Edit it by hand, see src/lib.rs docs."
    }
    Write-Utf8NoBom $binRs $rs
    Write-Host "registered config and components in bin/q35_dxe_core.rs"
} else { Write-Host "bin/q35_dxe_core.rs already registers hello_component" }

Write-Host ""
Write-Host "Next:  ..\..\build_q35.ps1 -LocalCore -Headless -Run   (then grep the output for [hello_component])"
