# UEFI DXE Core 的 Rust 开源实现调研

调研日期：2026-10-08

## 一句话结论

有，而且只有一个成熟的：**Patina**（微软主导、Open Device Partnership 托管，Apache-2.0）。
它是纯 Rust、符合 UEFI/PI 规范的 DXE Core，支持 x64 和 AArch64，README 自述已是
production-ready，部署在虚拟机和物理硬件上，每个 PR 都在 QEMU 上实际启动 Ubuntu 和 Windows 做验证。

"完整工程"要由三个仓库拼起来，缺一不可：

| 仓库 | 作用 | 地址 |
|---|---|---|
| patina | DXE Core 库 + SDK + 各组件（Rust workspace） | https://github.com/OpenDevicePartnership/patina |
| patina-dxe-core-qemu | 平台 binary crate，把库实例化成 `.efi`（Q35 / ARMVIRT / OVMF） | https://github.com/OpenDevicePartnership/patina-dxe-core-qemu |
| patina-qemu | 完整固件平台（EDK II/Project Mu 的 OvmfPkg 永久分支），把 Rust DXE Core `.efi` 塞进 FD，跑 QEMU | https://github.com/OpenDevicePartnership/patina-qemu |

文档（mdBook）：https://opendevicepartnership.github.io/patina/

## Patina 架构要点

- **crate 划分**：`patina_dxe_core`（核心：System Table、PI 兼容 dispatcher、内存/分页、GCD、事件、协议数据库）、
  `patina`（SDK，写组件用）、`patina_pi` / `patina_ffs` / `patina_paging` / `patina_mtrr` / `patina_debugger` 等。
  最新版本：patina_dxe_core 23.3.2（2026-10-07 发布到 crates.io）。
- **组件模型**：不是传统的独立 `.efi` 驱动，而是"Patina component"——纯 Rust、依赖注入、
  与 DXE Core 单体编译进同一个二进制。传统 C 写的 DXE 驱动仍可由 dispatcher 从 FV 里正常加载。
- **平台集成方式**（关键）：
  1. 自建一个独立的 Rust workspace（不混进 EDK II 构建系统）。
  2. 写一个 binary crate，实现 `PlatformInfo`（MemoryInfo / CpuInfo / ComponentInfo），
     `static CORE: Core<MyPlatform> = Core::new(...)`，导出 `efi_main(hob_list)` 入口。
  3. `cargo make` 编出 `.efi`，复制到 EDK II 平台目录，在 FDF 里替换掉 C 版 DxeCore。
  4. 正常跑 EDK II / stuart 构建。
- **仍需要 C 的部分**：SEC/PEI 阶段（Patina 需要 PEI 交付 HOB 列表、内存资源描述 HOB、FV HOB）、
  大部分 DXE 驱动（CpuDxe 等少数已被 Rust 组件替代）。路线是逐步把 C 组件迁到 Rust。

## 构建/工具链

- rustup + `rust-toolchain.toml` 钉死版本（第三方项目反映 Patina 当前要求 Rust 1.95）
- `cargo make`（必需），`cargo-llvm-cov`（覆盖率），`cargo-binstall`（可选）
- patina：`cargo make build-x64` / `build-aarch64` / `test` / `patina-test`
- patina-dxe-core-qemu：`cargo make q35` / `q35-release` / `armvirt` / `armvirt-release` / `ovmf*`
- patina-qemu：Python `workspace_setup.py` + stuart（EDK II 工具链），含 MU_BASECORE 子模块；
  有 Q35 和 ArmVirt 两个平台，文档含 WinDbg 调试 QEMU 的指南，每夜回归测试 Ubuntu/Windows 启动。

## 其他候选（都基于 Patina，不是独立实现）

| 项目 | 说明 | 适用性 |
|---|---|---|
| tinted-software/rust-firmware（Tinted-Boot） | QEMU AArch64 全 Rust 启动链：自写 reset 阶段直接构造 HOB，**不用 EDK2/PEI**，Patina 作子模块当 DXE Core；有 PL011、PCI、virtio-blk、GPT、FAT。缺 Variable 服务，仅 8 个 commit，无 license 声明 | 想看"零 C 代码"参考可读，不适合做基线 |
| Sunrise-OS/firmware | 同类/同源的小项目 | 同上 |
| Project Mu `mu_tiano_platforms` | 微软 Mu 的 Q35 虚拟平台，早期就在 CI 里集成 Rust DXE 模块；Patina 的前身 | 已被 patina-qemu 取代，作历史参考 |
| uefi-rs | Rust 写 UEFI 应用/驱动的安全封装 | 不是 DXE Core，只是 API wrapper |

## 建议的落地路径

1. clone `patina-qemu`，按其 docs 跑通 Q35（x64）QEMU 启动——这就是"完整工程"的最快入口，
   默认会从 NuGet feed 拉预编译的 Patina DXE Core。
2. clone `patina-dxe-core-qemu`，`cargo make q35` 自己编出 `.efi`，替换 patina-qemu 里的二进制，验证改动生效。
3. 要移植到自己的平台：复制 patina-dxe-core-qemu 的 binary crate，实现 `PlatformInfo`，
   把 `.efi` 挂到自家 EDK II/Mu 平台的 FDF 里；PEI 保持 C。
4. 要读核心源码：从 `patina/core/patina_dxe_core` 入手，重点看 dispatcher、GCD、事件/TPL 实现。

## 风险与注意

- 版本号跳得很快（11 → 13 → 23），API 还在演进，跟主线时要锁 crate 版本和 Rust 版本。
- patina_dxe_core 23.3.2 在 docs.rs 上的文档构建失败，看 API 请看 20.1.3 或本地 `cargo doc`。
- 社区有定期 community call（见 patina discussions #1270），问题优先去 GitHub Discussions。

---

# 实操记录（2026-10-08，Windows 11 主机）

## 结果

- `patina-qemu` QemuQ35Pkg（DEBUG, CLANGPDB）编译成功，耗时约 2.5 分钟，产物在
  `patina-qemu/Build/QemuQ35Pkg/DEBUG_CLANGPDB/FV/`（QEMUQ35_CODE.fd 3.6 MB，QEMUQ35_VARS.fd）。
- `patina-dxe-core-qemu` 用 `cargo make q35` 编出 `target/x86_64-unknown-uefi/debug/qemu_q35_dxe_core.efi`（1.19 MB）。
- QEMU（仓库 extdep 自带的 qemu-system-x86_64 11.0）无头启动两次均成功，日志见 `logs/`：
  - NuGet 预编译核心 v3.2.5：27 项 Patina 片上单元测试全通过，进入 UEFI Shell，`reset -s` 正常关机，14-17 秒。
  - 本地编译核心 v3.2.6：同上，日志中 `DXE Core Platform Binary v3.2.6` 证明替换生效。

## 一键脚本

`build_q35.ps1`（工程根目录）封装了全部环境设置：

```powershell
.\build_q35.ps1                      # 构建（NuGet 预编译 Patina DXE Core）
.\build_q35.ps1 -LocalCore -Run      # 本地 cargo make q35 + 构建 + 带窗口运行 QEMU
.\build_q35.ps1 -RunOnly             # 不重编，直接启动 QEMU 看画面
.\build_q35.ps1 -Headless -RunOnly   # 无头运行，日志打到控制台，Shell 自动关机
```

## 踩过的坑（都已在脚本里处理）

1. **`'GenSec' is not recognized`**：`Conf/tools_def.txt` 有 `*_CLANGPDB_*_*_DLL = ENV(CLANGPDB_DLL)`，该变量没人设置，
   EDK II AutoGen 把空串前置到 PATH，形成前导分号；这台 Windows 11 上 cmd.exe 遇到前导分号后任何命令都找不到。
   修复：构建前 `$env:CLANGPDB_DLL = <任意存在目录>`。
2. **clang 23 太新**：winget 装的 LLVM 23.1.3 触发 `-Wunused-but-set-global`，在 `-Werror` 下编译失败。
   修复：用官方 tar.xz 把 LLVM 21.1.8 解压到 `tools/LLVM21`，`CLANG_BIN` 指过去（文档推荐 21+，CI 也用 21）。
3. `rustup toolchain install` 的 `--target` 需要每个 target 单独写一次；cargo-binstall 新版要求 rustc 1.96，
   用默认 1.97 工具链 `cargo install cargo-make@0.37.21` 即可。

## 主机环境清单

| 组件 | 版本 / 位置 |
|---|---|
| Visual Studio Build Tools 2022 | MSVC 14.44，Windows SDK 10.0.26100（nmake、vcvars 用） |
| LLVM | 21.1.8 便携版 `tools/LLVM21`（另有 winget 装的 23.1.3 在 Program Files，未用） |
| Rust | 1.95.0（rust-toolchain.toml 钉死）+ x86_64/aarch64-unknown-uefi target |
| cargo-make | 0.37.21 |
| Python | 3.10 + edk2-pytool-library 0.23.17 / edk2-pytool-extensions 0.31.2 |
| QEMU | 仓库 extdep `QemuPkg/Binaries/qemu-win_extdep`（11.0.50） |

## Windows 支持

- **作为开发主机**：支持，本次全程在 Windows 11 上完成；文档明确 Windows 下 QEMU 由 extdep 提供，无需手装。
- **作为被启动的 OS**：支持。patina-qemu 每夜回归在 Q35 和 ArmVirt 上用 Windows Validation OS 做 SSD/USB 启动测试，
  Patina 自述每个 PR 都在 QEMU 上启动 Ubuntu 和 Windows。本地要启动 Windows，给 stuart_build 加
  `PATH_TO_OS=<vhdx 或 qcow2 路径>`（内存会自动提到 8 GB），镜像需自备；仓库还有 WinDbg 调试 Windows 来宾的指南
  （`docs/src/debugging/windbg_windows.md`）。
- **ArmVirt（aarch64）**：也能在 Windows 主机构建，但 Hafnium/TF-A 只能用预编译二进制（它们不在 Windows 上编译）。
