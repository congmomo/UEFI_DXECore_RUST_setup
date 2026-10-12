# Patina Rust DXE Core on QEMU — Windows one-click scripts

[English](#english) | [中文](#中文)

---

## English

Scripts that set up a Windows machine, build the **Patina** pure-Rust UEFI DXE Core and the
**patina-qemu** Q35 platform firmware that embeds it, and run the result in QEMU. Everything was
verified on Windows 11 (build 26200) on 2026-10-08: the firmware boots to the UEFI Shell, every Patina
on-system unit test passes (the number of tests that run varies with the configuration), and a locally
built DXE Core can replace the prebuilt one end to end.

### What is Patina?

[Patina](https://github.com/OpenDevicePartnership/patina) is the only production-grade open-source
UEFI DXE Core written in pure Rust (Microsoft-led, Apache-2.0, x64 + AArch64). Three upstream repos
form a complete working firmware:

| Repo | Role |
| --- | --- |
| [patina](https://github.com/OpenDevicePartnership/patina) | DXE Core library, SDK and components (crates on crates.io) |
| [patina-dxe-core-qemu](https://github.com/OpenDevicePartnership/patina-dxe-core-qemu) | Platform binary crate that turns the library into a `.efi` for Q35 / ARM Virt / OVMF |
| [patina-qemu](https://github.com/OpenDevicePartnership/patina-qemu) | Full EDK II / Project Mu firmware (OvmfPkg fork) that packs the `.efi` into a flash image and runs QEMU |

Only the DXE Core (plus a few drivers) is Rust; SEC/PEI and most DXE drivers are still C and are
built with the CLANGPDB toolchain. See the [Patina book](https://opendevicepartnership.github.io/patina/).

### Prerequisites

* Windows 10/11 x64, about 12 GB free disk, internet access (GitHub, crates.io, PyPI, NuGet, winget).
* `winget` (comes with modern Windows). The setup script uses it to install anything missing.
* Admin rights are only needed if Visual Studio Build Tools are not installed yet.

### Quick start

```powershell
git clone https://github.com/congmomo/UEFI_DXECore_RUST_setup.git patina
cd patina
Set-ExecutionPolicy -Scope Process Bypass

.\setup.ps1                   # one-time: tools, LLVM 21, clone upstream, Rust toolchain, pytools, stuart setup/update
.\build_q35.ps1               # build QemuQ35Pkg firmware (uses the prebuilt Patina DXE Core from NuGet)
.\build_q35.ps1 -RunOnly      # open a QEMU window with the firmware you just built
```

Build the Rust DXE Core yourself and boot it:

```powershell
.\build_q35.ps1 -LocalCore -Run
```

Look for `DXE Core Platform Binary v3.2.x` in the console log; the local build prints the version
from `patina-dxe-core-qemu/Cargo.toml`, the NuGet one prints the version pinned in
`patina-qemu/QemuPkg/Binaries/DXECORE.QEMU_ext_dep.json`.

### Scripts

#### `setup.ps1`

Idempotent environment setup. Re-run it any time; it only fills in what is missing.

| Step | Detail |
| --- | --- |
| Git, Python ≥ 3.10, rustup | checked, installed via winget if absent |
| Visual Studio 2022 Build Tools | needs the *Desktop development with C++* workload (nmake + vcvars). Installed via winget with that workload if absent |
| LLVM | portable `clang+llvm-21.1.8-x86_64-pc-windows-msvc.tar.xz` extracted to `tools\LLVM21`, no installer, no admin. `-LlvmVersion` overrides |
| Upstream repos | `patina-qemu` and `patina-dxe-core-qemu` cloned next to the script |
| Rust toolchain | the channel, UEFI targets and components pinned in `patina-dxe-core-qemu/rust-toolchain.toml`; `cargo-make` at the pinned version |
| Python packages | `pip install -r patina-qemu/pip-requirements.txt` (edk2-pytools) |
| `stuart_setup` / `stuart_update` | git submodules and external dependencies: QEMU for Windows, NASM, iasl, EDK II BaseTools binaries, prebuilt Patina DXE Core, OS test images |

Flags: `-NoInstall` (check only, never call winget), `-LlvmVersion`, `-PatinaQemuUrl`, `-DxeCoreQemuUrl`,
`-DebugTools` (also install WinDbg via winget, register its EXDi COM server, and put the UEFI WinDbg extension from
[microsoft/uefi_debug_tools](https://github.com/microsoft/uefi_debug_tools) into `tools\uefiext`;
`-UefiExtVersion <tag>` pins the extension release, default is the latest).

#### `build_q35.ps1`

Build and/or run the Q35 (x64) platform.

| Flag | Effect |
| --- | --- |
| *(none)* | `stuart_build` DEBUG firmware with the prebuilt Patina DXE Core |
| `-LocalCore` | `cargo make q35` in `patina-dxe-core-qemu`, then build the firmware with that `.efi` (`BLD_*_DXE_CORE_PATH`) |
| `-Release` | RELEASE target for both the Rust core and the firmware |
| `-Run` | launch QEMU with a display after building |
| `-RunOnly` | skip the build, launch QEMU with the last build |
| `-Headless` | no display, firmware log to the console, UEFI Shell runs `reset -s` so QEMU exits by itself (CI style) |
| `-OsImage <path>` | boot a VHDX/QCOW2 OS image instead of stopping at the UEFI Shell (`PATH_TO_OS`); memory is raised to 8 GB |
| `-EnableDebugger` | build the Rust core with the `enable_debugger` feature (implies `-LocalCore`): the Patina software debugger halts at an initial breakpoint and waits for WinDbg/GDB on COM1 |
| `-SerialPort <n>` | expose COM1 on TCP port `n` (`SERIAL_PORT`); with `-EnableDebugger` this is where WinDbg (EXDi) or GDB connect |
| `-GdbServer <n>` | enable QEMU's own gdbstub on TCP port `n` (`GDB_SERVER`), hardware-level debugging independent of the firmware |
| `-DryRun` | print environment and the `stuart_build` command line, run nothing |

Outputs: `patina-qemu\Build\QemuQ35Pkg\DEBUG_CLANGPDB\FV\QEMUQ35_CODE.fd` / `QEMUQ35_VARS.fd`,
`patina-dxe-core-qemu\target\x86_64-unknown-uefi\debug\qemu_q35_dxe_core.efi`. Full build logs are in
`patina-qemu\Build\BUILDLOG_QemuQ35Pkg.txt` and `BUILDLOG_QemuQ35Pkg_Run.txt`.

### Windows support

* **As the host:** yes, that is what these scripts are for. QEMU comes from the repo's own external
  dependency, no manual install.
* **As the guest OS:** yes. patina-qemu's nightly regression boots Windows Validation OS and Ubuntu
  24.04 on Q35 and ARM Virt from SSD and USB. Locally, pass `-OsImage <your.vhdx>`; you must supply the
  image. The repo ships WinDbg guides for both the firmware and a Windows guest
  (`patina-qemu/docs/src/debugging/`).
* **ARM Virt (AArch64):** builds on a Windows host too, but Hafnium/TF-A are consumed as prebuilt
  binaries there (they only compile on Linux). Not wrapped by these scripts.

### Debugging

Source-level debugging of the Rust DXE Core uses three pieces: the **Patina software debugger** compiled into the
core (`patina_debugger`, a GDB remote protocol stub on COM1), the **PDB symbols** that `cargo make q35` writes next
to the `.efi`, and **WinDbg** talking GDB remote protocol through its EXDi transport plus the UEFI extension from
[microsoft/uefi_debug_tools](https://github.com/microsoft/uefi_debug_tools). QEMU's own gdbstub is available as a
second, hardware-level channel. Details and background are in the
[learning guide, chapter 7](docs/learning-guide.en.md#7-debugging) and in upstream's
[`windbg_uefi.md`](patina-qemu/docs/src/debugging/windbg_uefi.md).

1. **One-time setup:** `.\setup.ps1 -DebugTools` installs [WinDbg](https://learn.microsoft.com/windows-hardware/drivers/debugger/)
   through winget (the Store build, which ships `ExdiGdbSrv.dll`), registers that DLL as a COM server (one UAC
   prompt; without it every EXDi connection fails with *Debugger must be run from an elevated command prompt to
   register the EXDI COM server*; `regsvr32` runs on a copy in `tools\exdi` because nothing outside the package can
   load DLLs from `WindowsApps`, then `InprocServer32` is pointed back at the package DLL, which WinDbg insists on)
   and extracts `UefiExt_x64.zip` from the latest
   [uefi_debug_tools release](https://github.com/microsoft/uefi_debug_tools/releases/latest) (`uefiext.dll`,
   `EfiSymComposition.dll`) into `tools\uefiext\`. Upstream suggests `%LOCALAPPDATA%\Dbg\EngineExtensions\`, but
   WinDbg 1.2610 cannot load the DLL from that folder (Win32 error 126) while it loads fine from anywhere else, so
   the extension is loaded by explicit path instead. Re-running updates it when a newer release exists.
2. **Build and start QEMU halted at the initial breakpoint:**

   ```powershell
   .\build_q35.ps1 -EnableDebugger -Run -SerialPort 50001 -GdbServer 5555
   ```

   `-EnableDebugger` builds the local core with the `enable_debugger` feature (DEBUG profile, PDB kept),
   `-SerialPort` puts COM1 on TCP 50001, `-GdbServer` opens QEMU's gdbstub on 5555 (optional). Add `-Headless` to
   keep the firmware log in the console. The boot stops after `*** Initial debug breakpoint! ***`.
3. **Attach WinDbg:** start WinDbg from the Start menu, then Start debugging → Attach to kernel → EXDI tab:
   target type *UEFI*, architecture *X64*, "Gdb server and port" `localhost:50001`, keep *Break on connection*
   checked (screenshots in `patina-qemu/docs/src/debugging/images/`). A message box *the
   EXDI_SYSTEM_REGISTERS_MAP_XML_FILE environment variable is not defined* may appear; it only disables
   `rdmsr`/`wrmsr`, click OK (or set that variable to `<WinDbg package>\amd64\systemregisters.xml` before starting
   WinDbg). The command window ends with `7b0a627c cc int 3`, the initial breakpoint. Then:

   ```text
   .sympath+ D:\path\to\patina-dxe-core-qemu\target\x86_64-unknown-uefi\debug
   .sympath+ D:\path\to\patina-qemu\Build\QemuQ35Pkg\DEBUG_CLANGPDB\PDB
   .load D:\path\to\tools\uefiext\uefiext.dll
   !uefiext.init
   k
   lsa @rip
   ```

   `k` should show `patina_debugger::...::initialize` with `debugger.rs @ 402`, then `patina_dxe_core::Core::entry_point`
   (`lib.rs @ 381`) and `qemu_q35_dxe_core::_start` (`q35_dxe_core.rs @ 137`); `lsa @rip` lists the source around
   `SystemArch::breakpoint();` and WinDbg opens the file in a source window.

   `!uefiext.init` reads the EFI debug image info table to enumerate loaded images and load their PDBs. If it
   finds nothing, register the core by hand with the base address printed in the boot log
   (`Loading PEIM at 0x0007B08A000 ... qemu_q35_dxe_core.efi`): `.reload /f qemu_q35_dxe_core.efi=0x7b08a000,0x131000`.
   The PDB records absolute source paths, so `.srcpath` is only needed when debugging on another machine. The
   `.efi` stores just the PDB file name (`/PDBALTPATH`), which is why the symbol path must be set.
4. **Work as usual:** pick a function that runs later, break there, continue, step through the Rust source:

   ```text
   x qemu_q35_dxe_core!patina_dxe_core::pi_dispatcher*     ; list candidates
   bp qemu_q35_dxe_core!<one of them>
   g
   k
   lsa @rip
   p                                                       ; step over, source level
   dv                                                      ; locals
   ```

   Data breakpoints (`ba`) work too. Patina-specific commands go through `!monitor <cmd>` (`!monitor help`,
   `!monitor mod` to list modules or break on a module load, `!monitor ?` for debugger state). A `panic!` calls
   `patina_debugger::breakpoint()`, so panics stop in the debugger instead of exiting QEMU. C drivers resolve
   through the CLANGPDB PDBs added above.
5. **Hardware-level fallback:** a second WinDbg instance (EXDi, port 5555) or `gdb -ex "target remote :5555"`
   talks to QEMU itself and still works when the firmware is wedged, but sees no Patina modules or symbols.

Notes: RELEASE builds have `debug = false` and cannot be source-debugged. GDB and LLDB can connect to 50001 and
step, but they do not read PE/PDB symbols, so function names stay unresolved. QEMU's serial socket serves one client
per run; after disconnecting, relaunch with `.\build_q35.ps1 -RunOnly -Run -SerialPort 50001 -GdbServer 5555`.
Use the WinDbg app (WinDbgX); the console `kd.exe -kx exdi:...,InProc=ExdiGdbSrv.dll` route coincided with two
host freezes on the test machine and is not recommended. Verified on 2026-10-12: WinDbgX attaches through EXDI,
the core halts at the initial breakpoint (`7b0a627c cc int 3`), `k` shows the Rust frames with source lines
(`patina_debugger\...\debugger.rs @ 402`, `patina_dxe_core\...\lib.rs @ 381`, `bin\q35_dxe_core.rs @ 137`) and
`lsa @rip` lists the Rust source around `SystemArch::breakpoint()`. Port 50001 answers the GDB stop packet
`$T05thread:01;#07`, 5555 QEMU's `$T05core:01;#38`.

### Troubleshooting (both already handled by the scripts)

1. **`'GenSec' is not recognized as an internal or external command`** seconds into `stuart_build`,
   although the BaseTools directory is on PATH. `Conf/tools_def.txt` contains
   `*_CLANGPDB_*_*_DLL = ENV(CLANGPDB_DLL)`; nothing defines `CLANGPDB_DLL`, so EDK II's
   `PlatformAutoGen.py` prepends an empty string to PATH. A PATH that starts with `;` makes `cmd.exe` on
   current Windows 11 builds fail to resolve *any* command. Fix: set `CLANGPDB_DLL` to any existing
   directory before building (`build_q35.ps1` does).
2. **`error: variable ... set but not used [-Werror,-Wunused-but-set-global]`** with LLVM 23 from winget.
   The codebase builds with `-Werror` and is validated with LLVM 21. Fix: use LLVM 21.x and point
   `CLANG_BIN` at it (`setup.ps1` downloads it, `build_q35.ps1` sets the variable).
3. `rustup toolchain install` needs one `--target` per target; the newest `cargo-binstall` requires a
   newer rustc than the pinned 1.95, so `cargo install cargo-make@<ver>` is used instead.
4. **`error: unable to create file ...: Filename too long`** while `stuart_setup` clones `MU_BASECORE`.
   The EDK II tree has paths longer than 260 characters. `setup.ps1` sets `core.longpaths=true` for every
   git process it starts (via `GIT_CONFIG_PARAMETERS`, without touching your global config) and warns if the
   checkout directory itself is deep. Keep the repository in a short path such as `C:\src\patina`.

### Verified results

Recorded boot logs live in [`logs/`](logs/); the learning guide cites them by line number.

| Log | Firmware | Mode | Result |
| --- | --- | --- | --- |
| [qemu_q35_nuget_core_v3.2.5.log](logs/qemu_q35_nuget_core_v3.2.5.log) | prebuilt Patina DXE Core from NuGet | headless | boots to Shell, 27 tests pass, `reset -s` |
| [qemu_q35_local_core_v3.2.6.log](logs/qemu_q35_local_core_v3.2.6.log) | locally built `cargo make q35` | headless | same, `DXE Core Platform Binary v3.2.6` |
| [qemu_q35_hello_component.log](logs/qemu_q35_hello_component.log) | local core + `examples/hello_component` | headless | 29 tests pass incl. the two example tests |
| [qemu_q35_hello_component_window.log](logs/qemu_q35_hello_component_window.log) | local core + `examples/hello_component` | display window | 34 tests pass, Shell stays up |

On-system test output from the windowed run (`logs/qemu_q35_hello_component_window.log`, lines 4307–4322):

```
Patina on-system unit-test results:
  hello_component::tests::greeting_matches_config ... ok (1 passes)
  hello_component::tests::greeting_service_exists ... ok (1 passes)
  patina_acpi::integration_test::acpi_protocol_test ... ok (1 passes)
  patina_acpi::integration_test::acpi_test ... ok (1 passes)
  patina_adv_logger::integration_test::adv_logger_test ... ok (1 passes)
  patina_dxe_core::core_patina_tests::audit_tests::gcd_free_memory_merged_test ... ok (1 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_1gb_split ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_1gb_unmap_2mb_remap ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_1gb_unmap_4kb_remap ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_2mb_split ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_2mb_unmap ... ok (5 passes)
  patina_dxe_core::memory_manager::memory_manager_allocations_test ... ok (1 passes)
  patina_dxe_core::memory_manager::memory_manager_attributes_test ... ok (1 passes)
Patina on-system unit-test result totals: 34 passes, 0 fails
```

The total varies between runs (the page-table stability tests iterate over every GCD region, and a display
device adds MMIO regions), so treat `0 fails` as the pass criterion, not the count.

### Learning guide

A nine-chapter guide for C firmware engineers, built around this repository: boot-log anatomy, the DXE Core
entry path, the component model, a hands-on component (`examples/hello_component`), C interop, debugging,
porting to your own platform. [English](docs/learning-guide.en.md) · [中文](docs/learning-guide.zh.md).

### Repository layout

```
setup.ps1                   environment setup and downloads
build_q35.ps1               build / run
README.md                   this file
docs/learning-guide.en.md   learning guide (English)
docs/learning-guide.zh.md   learning guide (中文)
examples/hello_component/   chapter-5 example component + apply.ps1 to wire it into patina-dxe-core-qemu
Rust_DXE_Core_调研报告.md    research notes (Chinese): Patina architecture, alternatives, hands-on record
logs/                       recorded QEMU boot logs cited by the guide (user paths scrubbed)
.gitignore                  excludes patina-qemu/, patina-dxe-core-qemu/, tools/
```

Upstream licenses: Patina and patina-dxe-core-qemu are Apache-2.0; patina-qemu is BSD-2-Clause-Patent.
Nothing from them is vendored into this repository.

---

## 中文

一组 Windows 脚本：配置环境、编译 **Patina** 纯 Rust UEFI DXE Core 以及内嵌它的 **patina-qemu** Q35
平台固件，并在 QEMU 中运行。2026-10-08 在 Windows 11（26200）上全程验证：固件启动到 UEFI Shell，
Patina 片上单元测试全部通过（实际运行的测试数量随配置变化），本地编译的 DXE Core 可以端到端替换预编译版本。

### Patina 是什么

[Patina](https://github.com/OpenDevicePartnership/patina) 是目前唯一达到生产级的纯 Rust 开源 UEFI
DXE Core（微软主导，Apache-2.0，支持 x64 和 AArch64）。一个完整可运行的固件由三个上游仓库拼成：

| 仓库 | 作用 |
| --- | --- |
| [patina](https://github.com/OpenDevicePartnership/patina) | DXE Core 库、SDK 和组件（crates.io 发布） |
| [patina-dxe-core-qemu](https://github.com/OpenDevicePartnership/patina-dxe-core-qemu) | 平台 binary crate，把库实例化成 Q35 / ARM Virt / OVMF 的 `.efi` |
| [patina-qemu](https://github.com/OpenDevicePartnership/patina-qemu) | 完整的 EDK II / Project Mu 固件（OvmfPkg 分支），把 `.efi` 打进 flash 镜像并启动 QEMU |

只有 DXE Core（加少量驱动）是 Rust；SEC/PEI 和绝大多数 DXE 驱动仍是 C，用 CLANGPDB 工具链编译。
详见 [Patina 文档书](https://opendevicepartnership.github.io/patina/)。

### 前置条件

* Windows 10/11 x64，约 12 GB 空闲磁盘，可访问 GitHub、crates.io、PyPI、NuGet、winget。
* `winget`（新版 Windows 自带），缺什么脚本就用它装什么。
* 只有在尚未安装 Visual Studio Build Tools 时才需要管理员权限。

### 快速开始

```powershell
git clone https://github.com/congmomo/UEFI_DXECore_RUST_setup.git patina
cd patina
Set-ExecutionPolicy -Scope Process Bypass

.\setup.ps1                   # 一次性：工具、LLVM 21、clone 上游、Rust 工具链、pytools、stuart setup/update
.\build_q35.ps1               # 编译 QemuQ35Pkg 固件（使用 NuGet 预编译的 Patina DXE Core）
.\build_q35.ps1 -RunOnly      # 用刚编好的固件弹出 QEMU 窗口
```

自己编译 Rust DXE Core 并启动：

```powershell
.\build_q35.ps1 -LocalCore -Run
```

在控制台日志里找 `DXE Core Platform Binary v3.2.x`：本地编译打印的是 `patina-dxe-core-qemu/Cargo.toml`
里的版本，NuGet 版本打印的是 `patina-qemu/QemuPkg/Binaries/DXECORE.QEMU_ext_dep.json` 钉死的版本。

### 脚本说明

#### `setup.ps1`

幂等的环境配置，随时可以重跑，只补缺失的部分。

| 步骤 | 说明 |
| --- | --- |
| Git、Python ≥ 3.10、rustup | 检查，缺失则用 winget 安装 |
| Visual Studio 2022 Build Tools | 需要“使用 C++ 的桌面开发”工作负载（nmake + vcvars）。缺失则用 winget 带该工作负载安装 |
| LLVM | 便携版 `clang+llvm-21.1.8-x86_64-pc-windows-msvc.tar.xz` 解压到 `tools\LLVM21`，无安装器、无需管理员。`-LlvmVersion` 可改版本 |
| 上游仓库 | `patina-qemu` 和 `patina-dxe-core-qemu` clone 到脚本旁边 |
| Rust 工具链 | 按 `patina-dxe-core-qemu/rust-toolchain.toml` 钉死的 channel、UEFI target 和组件安装；`cargo-make` 装钉死版本 |
| Python 包 | `pip install -r patina-qemu/pip-requirements.txt`（edk2-pytools） |
| `stuart_setup` / `stuart_update` | git 子模块和外部依赖：Windows 版 QEMU、NASM、iasl、EDK II BaseTools 二进制、预编译 Patina DXE Core、OS 测试镜像 |

参数：`-NoInstall`（只检查，不调用 winget）、`-LlvmVersion`、`-PatinaQemuUrl`、`-DxeCoreQemuUrl`、
`-DebugTools`（额外通过 winget 安装 WinDbg、注册它的 EXDi COM 服务器，并把 [microsoft/uefi_debug_tools](https://github.com/microsoft/uefi_debug_tools)
的 UEFI WinDbg 扩展放到 `tools\uefiext`；`-UefiExtVersion <tag>` 固定扩展版本，默认取最新 release）。

#### `build_q35.ps1`

编译和/或运行 Q35（x64）平台。

| 参数 | 效果 |
| --- | --- |
| *（无）* | `stuart_build` DEBUG 固件，使用预编译 Patina DXE Core |
| `-LocalCore` | 先在 `patina-dxe-core-qemu` 执行 `cargo make q35`，再用该 `.efi` 编固件（`BLD_*_DXE_CORE_PATH`） |
| `-Release` | Rust 核心和固件都用 RELEASE |
| `-Run` | 编译后带显示窗口启动 QEMU |
| `-RunOnly` | 跳过编译，用上次产物启动 QEMU |
| `-Headless` | 无显示，固件日志打到控制台，UEFI Shell 自动执行 `reset -s` 让 QEMU 自行退出（CI 方式） |
| `-OsImage <路径>` | 启动 VHDX/QCOW2 操作系统镜像而不是停在 Shell（`PATH_TO_OS`），内存自动提到 8 GB |
| `-EnableDebugger` | 用 `enable_debugger` feature 编译 Rust 核（隐含 `-LocalCore`）：Patina 软件调试器会停在初始断点，在 COM1 上等 WinDbg/GDB 连接 |
| `-SerialPort <n>` | 把 COM1 暴露在 TCP 端口 `n`（`SERIAL_PORT`）；配合 `-EnableDebugger`，WinDbg（EXDi）或 GDB 就连这个端口 |
| `-GdbServer <n>` | 在 TCP 端口 `n` 打开 QEMU 自带的 gdbstub（`GDB_SERVER`），硬件级调试，不依赖固件 |
| `-DryRun` | 只打印环境变量和 `stuart_build` 命令行，不执行 |

产物：`patina-qemu\Build\QemuQ35Pkg\DEBUG_CLANGPDB\FV\QEMUQ35_CODE.fd` / `QEMUQ35_VARS.fd`，
`patina-dxe-core-qemu\target\x86_64-unknown-uefi\debug\qemu_q35_dxe_core.efi`。完整日志在
`patina-qemu\Build\BUILDLOG_QemuQ35Pkg.txt` 和 `BUILDLOG_QemuQ35Pkg_Run.txt`。

### Windows 支持

* **作为开发主机**：支持，这套脚本就是为此而写。QEMU 由仓库自带的外部依赖提供，无需手动安装。
* **作为被启动的操作系统**：支持。patina-qemu 每夜回归在 Q35 和 ARM Virt 上从 SSD、USB 启动
  Windows Validation OS 和 Ubuntu 24.04。本地用 `-OsImage <你的.vhdx>`，镜像需自备。仓库附带固件和
  Windows 来宾两套 WinDbg 调试指南（`patina-qemu/docs/src/debugging/`）。
* **ARM Virt（AArch64）**：也能在 Windows 主机上编译，但 Hafnium/TF-A 只能用预编译二进制（它们只在
  Linux 上编译）。本脚本未封装。

### 调试

Rust DXE Core 的源码级调试由三部分组成：编进核里的 **Patina 软件调试器**（`patina_debugger`，在 COM1 上跑 GDB
远程协议）、`cargo make q35` 生成在 `.efi` 旁边的 **PDB 符号**、以及通过 EXDi 传输层说 GDB 协议的 **WinDbg** 加
[microsoft/uefi_debug_tools](https://github.com/microsoft/uefi_debug_tools) 的 UEFI 扩展。QEMU 自带的 gdbstub 是
第二条硬件级通道。原理见[学习指导第 7 章](docs/learning-guide.zh.md#7-调试)，上游文档见
[`windbg_uefi.md`](patina-qemu/docs/src/debugging/windbg_uefi.md)。

1. **一次性准备**：`.\setup.ps1 -DebugTools` 通过 winget 安装 [WinDbg](https://learn.microsoft.com/windows-hardware/drivers/debugger/)
   （商店版，自带 `ExdiGdbSrv.dll`），把这个 DLL 注册为 COM 服务器（弹一次 UAC；不注册的话每次 EXDi 连接都会报
   *Debugger must be run from an elevated command prompt to register the EXDI COM server*；`regsvr32` 在 `tools\exdi`
   的副本上执行，因为包外进程无法加载 `WindowsApps` 里的 DLL，之后再把 `InprocServer32` 指回包内的 DLL，WinDbg 只认这个路径），
   再把最新
   [uefi_debug_tools release](https://github.com/microsoft/uefi_debug_tools/releases/latest) 的 `UefiExt_x64.zip`
   （`uefiext.dll`、`EfiSymComposition.dll`）解压到 `tools\uefiext\`。上游建议放 `%LOCALAPPDATA%\Dbg\EngineExtensions\`，
   但 WinDbg 1.2610 从那个目录加载会报 Win32 错误 126，放在其他任何目录都正常，所以改为按路径显式加载。再次运行时如有新版本会自动更新扩展。
2. **编译并让 QEMU 停在初始断点**：

   ```powershell
   .\build_q35.ps1 -EnableDebugger -Run -SerialPort 50001 -GdbServer 5555
   ```

   `-EnableDebugger` 用 `enable_debugger` feature 编本地核（DEBUG profile，保留 PDB），`-SerialPort` 把 COM1
   放到 TCP 50001，`-GdbServer` 打开 QEMU gdbstub 的 5555（可选）。加 `-Headless` 可以把固件日志留在控制台。
   启动会停在 `*** Initial debug breakpoint! ***`。
3. **连接 WinDbg**：从开始菜单启动 WinDbg，Start debugging → Attach to kernel → EXDI 页：Target type 选 *UEFI*，
   架构 *X64*，"Gdb server and port" 填 `localhost:50001`，保持勾选 *Break on connection*（截图在
   `patina-qemu/docs/src/debugging/images/`）。可能弹出 *the EXDI_SYSTEM_REGISTERS_MAP_XML_FILE environment variable
   is not defined*，它只影响 `rdmsr`/`wrmsr`，点 OK 即可（或在启动 WinDbg 前把该变量设为
   `<WinDbg 包目录>\amd64\systemregisters.xml`）。命令窗口最后一行是 `7b0a627c cc int 3`，即初始断点。然后：

   ```text
   .sympath+ D:\path\to\patina-dxe-core-qemu\target\x86_64-unknown-uefi\debug
   .sympath+ D:\path\to\patina-qemu\Build\QemuQ35Pkg\DEBUG_CLANGPDB\PDB
   .load D:\path\to\tools\uefiext\uefiext.dll
   !uefiext.init
   k
   lsa @rip
   ```

   `k` 应显示 `patina_debugger::...::initialize`（`debugger.rs @ 402`）、`patina_dxe_core::Core::entry_point`
   （`lib.rs @ 381`）、`qemu_q35_dxe_core::_start`（`q35_dxe_core.rs @ 137`）三层；`lsa @rip` 列出
   `SystemArch::breakpoint();` 周围的源码，WinDbg 会同时打开源码窗口。

   `!uefiext.init` 读 EFI debug image info table 枚举已加载镜像并装载各自的 PDB。如果它什么都没找到，用启动日志里的
   基地址手动登记核镜像（`Loading PEIM at 0x0007B08A000 ... qemu_q35_dxe_core.efi`）：
   `.reload /f qemu_q35_dxe_core.efi=0x7b08a000,0x131000`。PDB 里记的是源码绝对路径，同一台机器上不需要 `.srcpath`。
   `.efi` 只存 PDB 文件名（`/PDBALTPATH`），所以符号路径必须设。
4. **正常调试**：找一个稍后才会执行的函数下断点，放行，再按源码单步：

   ```text
   x qemu_q35_dxe_core!patina_dxe_core::pi_dispatcher*     ; 列出候选函数
   bp qemu_q35_dxe_core!<从中挑一个>
   g
   k
   lsa @rip
   p                                                       ; 源码级单步
   dv                                                      ; 局部变量
   ```

   数据断点（`ba`）也可用。Patina 特有的命令走 `!monitor <cmd>`（`!monitor help`，`!monitor mod` 列模块或在某模块
   加载时停，`!monitor ?` 看调试器状态）。`panic!` 会调用 `patina_debugger::breakpoint()`，所以 panic 会停在调试器里
   而不是让 QEMU 退出。C 驱动通过上面加的 CLANGPDB PDB 解析。
5. **硬件级兜底**：再开一个 WinDbg（EXDi，端口 5555）或 `gdb -ex "target remote :5555"` 直接连 QEMU，固件
   自己挂死时也能用，但看不到 Patina 的模块和符号。

注意：RELEASE 构建 `debug = false`，不能源码级调试。GDB 和 LLDB 能连 50001 并单步，但它们不读 PE/PDB 符号，函数名
解析不出来。QEMU 的串口 socket 一次运行只服务一个客户端，断开后用
`.\build_q35.ps1 -RunOnly -Run -SerialPort 50001 -GdbServer 5555` 重新启动。请用 WinDbg 应用（WinDbgX）；命令行
`kd.exe -kx exdi:...,InProc=ExdiGdbSrv.dll` 这条路在测试机上两次伴随主机死机，不建议使用。以上流程于 2026-10-12 验证：
WinDbgX 通过 EXDI 连上，核停在初始断点（`7b0a627c cc int 3`），`k` 显示带源码行号的 Rust 栈
（`patina_debugger\...\debugger.rs @ 402`、`patina_dxe_core\...\lib.rs @ 381`、`bin\q35_dxe_core.rs @ 137`），
`lsa @rip` 列出 `SystemArch::breakpoint()` 周围的 Rust 源码。50001 返回 GDB 停机包 `$T05thread:01;#07`，5555 返回
QEMU 的 `$T05core:01;#38`。

### 常见问题（脚本均已处理）

1. **`stuart_build` 开始几秒就报 `'GenSec' is not recognized as an internal or external command`**，
   而 BaseTools 目录明明在 PATH 里。`Conf/tools_def.txt` 有 `*_CLANGPDB_*_*_DLL = ENV(CLANGPDB_DLL)`，
   没有任何地方定义 `CLANGPDB_DLL`，EDK II 的 `PlatformAutoGen.py` 把空串前置到 PATH；以 `;` 开头的
   PATH 会让当前 Windows 11 的 `cmd.exe` 找不到*任何*命令。修复：构建前把 `CLANGPDB_DLL` 设成任意存在的
   目录（`build_q35.ps1` 已做）。
2. **winget 的 LLVM 23 报 `error: variable ... set but not used [-Werror,-Wunused-but-set-global]`**。
   代码库用 `-Werror` 并以 LLVM 21 验证。修复：用 LLVM 21.x 并把 `CLANG_BIN` 指过去
   （`setup.ps1` 负责下载，`build_q35.ps1` 负责设置变量）。
3. `rustup toolchain install` 的每个 target 要单独写 `--target`；最新 `cargo-binstall` 要求的 rustc
   比钉死的 1.95 新，所以改用 `cargo install cargo-make@<版本>`。
4. **`stuart_setup` clone `MU_BASECORE` 时报 `error: unable to create file ...: Filename too long`**。
   EDK II 代码树里有超过 260 字符的路径。`setup.ps1` 通过 `GIT_CONFIG_PARAMETERS` 给它启动的每个 git
   进程设置 `core.longpaths=true`（不改你的全局配置），并在仓库目录本身过深时给出警告。请把仓库放在
   `C:\src\patina` 这样的短路径下。

### 验证结果

实际跑出来的启动日志放在 [`logs/`](logs/)，学习指导按行号引用它们。

| 日志 | 固件 | 模式 | 结果 |
| --- | --- | --- | --- |
| [qemu_q35_nuget_core_v3.2.5.log](logs/qemu_q35_nuget_core_v3.2.5.log) | NuGet 预编译 Patina DXE Core | 无头 | 进 Shell，27 项测试通过，`reset -s` 关机 |
| [qemu_q35_local_core_v3.2.6.log](logs/qemu_q35_local_core_v3.2.6.log) | 本地 `cargo make q35` 编译 | 无头 | 同上，日志出现 `DXE Core Platform Binary v3.2.6` |
| [qemu_q35_hello_component.log](logs/qemu_q35_hello_component.log) | 本地核心 + `examples/hello_component` | 无头 | 29 项通过，含示例的两个测试 |
| [qemu_q35_hello_component_window.log](logs/qemu_q35_hello_component_window.log) | 本地核心 + `examples/hello_component` | 带显示窗口 | 34 项通过，Shell 保持运行 |

带窗口那次的片上测试输出（`logs/qemu_q35_hello_component_window.log` 第 4307 到 4322 行）：

```
Patina on-system unit-test results:
  hello_component::tests::greeting_matches_config ... ok (1 passes)
  hello_component::tests::greeting_service_exists ... ok (1 passes)
  patina_acpi::integration_test::acpi_protocol_test ... ok (1 passes)
  patina_acpi::integration_test::acpi_test ... ok (1 passes)
  patina_adv_logger::integration_test::adv_logger_test ... ok (1 passes)
  patina_dxe_core::core_patina_tests::audit_tests::gcd_free_memory_merged_test ... ok (1 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_1gb_split ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_1gb_unmap_2mb_remap ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_1gb_unmap_4kb_remap ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_2mb_split ... ok (5 passes)
  patina_dxe_core::core_patina_tests::stability_tests::page_table_tests_2mb_unmap ... ok (5 passes)
  patina_dxe_core::memory_manager::memory_manager_allocations_test ... ok (1 passes)
  patina_dxe_core::memory_manager::memory_manager_attributes_test ... ok (1 passes)
Patina on-system unit-test result totals: 34 passes, 0 fails
```

总数在不同运行间会变（页表稳定性测试会遍历 GCD 里的每个区域，显示设备会多出 MMIO 区域），
所以以 `0 fails` 为通过标准，不看总数。

### 学习指导

面向 C 固件工程师的九章指南，围绕本仓库展开：启动日志剖析、DXE Core 入口路径、组件模型、动手写组件
（`examples/hello_component`）、与 C 互操作、调试、移植到自己的平台。
[中文](docs/learning-guide.zh.md) · [English](docs/learning-guide.en.md)。

### 仓库结构

```
setup.ps1                   环境配置与下载
build_q35.ps1               编译 / 运行
README.md                   本文件
docs/learning-guide.zh.md   学习指导（中文）
docs/learning-guide.en.md   学习指导（English）
examples/hello_component/   第 5 章示例组件 + apply.ps1（接入 patina-dxe-core-qemu）
Rust_DXE_Core_调研报告.md    调研笔记：Patina 架构、替代项目、实操记录
logs/                       指南引用的 QEMU 启动日志（已抹掉用户路径）
.gitignore                  排除 patina-qemu/、patina-dxe-core-qemu/、tools/
```

上游许可证：Patina 和 patina-dxe-core-qemu 为 Apache-2.0，patina-qemu 为 BSD-2-Clause-Patent。
本仓库不包含它们的任何代码。
