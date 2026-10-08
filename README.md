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
git clone <this repo> UEFI_DXE_RUST
cd UEFI_DXE_RUST
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

Flags: `-NoInstall` (check only, never call winget), `-LlvmVersion`, `-PatinaQemuUrl`, `-DxeCoreQemuUrl`.

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

### Repository layout

```
setup.ps1                   environment setup and downloads
build_q35.ps1               build / run
README.md                   this file
Rust_DXE_Core_调研报告.md    research notes (Chinese): Patina architecture, alternatives, hands-on record
.gitignore                  excludes patina-qemu/, patina-dxe-core-qemu/, tools/, logs/
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
git clone <本仓库> UEFI_DXE_RUST
cd UEFI_DXE_RUST
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

参数：`-NoInstall`（只检查，不调用 winget）、`-LlvmVersion`、`-PatinaQemuUrl`、`-DxeCoreQemuUrl`。

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

### 仓库结构

```
setup.ps1                   环境配置与下载
build_q35.ps1               编译 / 运行
README.md                   本文件
Rust_DXE_Core_调研报告.md    调研笔记：Patina 架构、替代项目、实操记录
.gitignore                  排除 patina-qemu/、patina-dxe-core-qemu/、tools/、logs/
```

上游许可证：Patina 和 patina-dxe-core-qemu 为 Apache-2.0，patina-qemu 为 BSD-2-Clause-Patent。
本仓库不包含它们的任何代码。
