# Patina 学习指导：C 固件工程师读懂 Rust DXE Core

> 读者定位：写过 EDK II 的 C 固件工程师。Rust 不要求精通，用到的概念在用到的地方解释。
> 版本基线：patina 23.3.2、patina-dxe-core-qemu 3.2.6、patina-qemu 2026-10 主线、Windows 11 主机。
> 每章末尾有"检查点"：几个自测问题，以及一条要在 QEMU 日志里亲手找到的证据。
> 日志引用均来自本仓库 `logs/qemu_q35_local_core_v3.2.6.log`，行号以该文件为准。

[English version](learning-guide.en.md)

## 目录

1. [全景图](#1-全景图)
2. [先跑起来，学会看日志](#2-先跑起来学会看日志)
3. [DXE Core 入口与内存初始化](#3-dxe-core-入口与内存初始化)
4. [组件模型与依赖注入](#4-组件模型与依赖注入)
5. [动手写第一个组件](#5-动手写第一个组件)
6. [与 C 世界互操作](#6-与-c-世界互操作)
7. [调试](#7-调试)
8. [从 QEMU 到自己的平台](#8-从-qemu-到自己的平台)
9. [跟上游一起演进](#9-跟上游一起演进)
- [附录 A：Patina 代码里的 Rust 速查](#附录-apatina-代码里的-rust-速查)
- [附录 B：常见报错对照表](#附录-b常见报错对照表)
- [附录 C：术语表](#附录-c术语表)

---

## 1. 全景图

### 这章解决什么问题

你已经会在 EDK II 里写 DXE 驱动。这章回答三个问题：Patina 替换了启动流程里的哪一块、没替换哪些、你敲下 `build_q35.ps1 -LocalCore -Run` 之后到底发生了什么。

### 1.1 UEFI 启动阶段里 Patina 的位置

```
 SEC ──> PEI ──────────────> DXE ─────────────────────> BDS ──> OS
 (C)     (C, 32 位)          │                          (C)
                             │  DXE Core        ← Patina（Rust，64 位）
                             │  CpuDxe 的功能    ← Patina 内置组件
                             │  RuntimeDxe 的功能← Patina 内置
                             │  其余 DXE 驱动    ← 仍是 C，从 FV 里正常分发
```

记住三条边界：

- **PEI 仍然是 C。** Patina 的入口只认一个参数：HOB 列表指针。PEI 必须把内存资源描述 HOB、FV HOB、平台配置 HOB 准备好。这决定了第 8 章移植时 PEI 侧要做什么。
- **DXE Core 整体是 Rust。** 不是"C 核心套 Rust 外壳"。System Table、Boot Services、GCD、事件/TPL、协议数据库、镜像加载、分发器，全部是 `patina_dxe_core` crate 里的 Rust 代码。
- **C 驱动照常跑。** Patina 的 PI 分发器从 FV 里读 FFS 文件、加载 PE32、按 depex 分发，和 Tiano DxeCore 一样。你现有的 C 驱动不用改。

### 1.2 三个仓库各管什么

| 仓库 | 产物 | 你会在哪章碰到 |
| --- | --- | --- |
| `patina`（crates.io 上发布为 `patina_dxe_core`、`patina` 等一组 crate） | 库。DXE Core 实现 + 写组件用的 SDK | 第 3、4、6 章读源码 |
| `patina-dxe-core-qemu` | 一个 binary crate，把库实例化成 `qemu_q35_dxe_core.efi` | 第 5 章改它，第 8 章仿它 |
| `patina-qemu` | 完整固件平台（OvmfPkg 分支），把 `.efi` 塞进 FD，启动 QEMU | 第 2 章读它的日志，第 6 章读它的 FDF |

本机源码位置：`patina` 系列 crate 在 `%USERPROFILE%\.cargo\registry\src\<index>\patina_dxe_core-23.3.2\` 等目录下，可以直接用编辑器打开。后文写 `patina_dxe_core/src/lib.rs` 就是指这里。

### 1.3 一次构建背后的数据流

```
patina-dxe-core-qemu/bin/q35_dxe_core.rs     ┐
patina-dxe-core-qemu/src/q35/**              │ cargo make q35
patina_dxe_core / patina / patina_* (registry)┘      │
                                                     ▼
          target/x86_64-unknown-uefi/debug/qemu_q35_dxe_core.efi   (PE32+，subsystem = EFI boot service driver)
                                                     │
patina-qemu/Platforms/QemuQ35Pkg/QemuQ35Pkg.fdf      │ stuart_build ... BLD_*_DXE_CORE_PATH=...
   [FV.RUST_DXE_CORE]  FILE DXE_CORE = 23C9322F-... {SECTION PE32 = $(DXE_CORE_PATH)/debug/qemu_q35_dxe_core.efi}
                                                     ▼
          Build/QemuQ35Pkg/DEBUG_CLANGPDB/FV/QEMUQ35_CODE.fd  +  QEMUQ35_VARS.fd
                                                     │ qemu-system-x86_64 -drive if=pflash,...
                                                     ▼
          PEI (C) 找到 FV.RUST_DXE_CORE 里的 DXE_CORE 文件 ──> 跳到 efi_main(hob_list)
```

两个值得注意的设计：

- Rust 侧是**独立 workspace**，用标准 cargo 工具链，不混进 EDK II 的 build 系统。EDK II 只认一个现成的 `.efi`。这就是为什么 `build_q35.ps1` 先跑 `cargo make`，再跑 `stuart_build`。
- 整个 Rust DXE Core 加上它所有的组件是**一个单体二进制**。Patina 组件不是独立 `.efi`，而是和核心一起静态链接。第 4 章会讲这带来的好处。

### 检查点

- PEI 交给 Patina 的唯一参数是什么？（HOB 列表指针）
- CpuDxe 还需要放进 FDF 吗？（不需要，`CpuArchProtocolInstaller` 组件接管了）
- **日志证据**：在 `logs/qemu_q35_local_core_v3.2.6.log` 第 4231、4232 行找到 `DXE Core Platform Binary v3.2.6` 和 `DXE Core Crate v23.3.2`。前者来自 `bin/q35_dxe_core.rs` 的 `_start`，后者来自 `patina_dxe_core/src/lib.rs` 的 `init_memory`。两行之间就是 C 到 Rust 的交接点。

---

## 2. 先跑起来，学会看日志

### 这章解决什么问题

后面每一章都要你在日志里找证据，所以先把一份完整启动日志按阶段切开，并把每一段对到源码。

### 2.1 产生一份日志

```powershell
.\build_q35.ps1 -RunOnly -Headless > my_boot.log 2>&1
```

无头模式下固件日志通过 QEMU 的 `-debugcon stdio` 打到控制台（I/O 端口 0x402，见 `q35_dxe_core.rs` 里 `Uart16550::new_io(0x402)`），UEFI Shell 自动执行 `reset -s` 关机。日志前面三百多行是 stuart 自己的输出，真正的固件输出从 `qemu-system-x86_64` 这条命令之后开始。

### 2.2 日志分段（以 `logs/qemu_q35_local_core_v3.2.6.log` 为例）

| 行号 | 标志性内容 | 谁打印的 | 对应源码 |
| --- | --- | --- | --- |
| 约 330 | `Cmd to run is: ...qemu-system-x86_64 -debugcon stdio ...` | stuart | `Platforms/QemuQ35Pkg/Plugins/QemuRunner/QemuRunner.py` |
| 330 ~ 4230 | SEC/PEI 输出：`QemuFwCfg`、`Q35TsegMbytesInitialization`、`Stack Guard set at`、MM Supervisor 加载、`Patch page table done!` | **C 代码** | `patina-qemu/Platforms/QemuQ35Pkg/PlatformPei`、`Features/MM_SUPV` |
| 4231 | `DXE Core Platform Binary v3.2.6` | Rust，平台 binary | `q35_dxe_core.rs::_start` |
| 4232 | `DXE Core Crate v23.3.2` | Rust，库 | `lib.rs::init_memory` 第一行 |
| 4232 ~ 4790 | `HOB list discovered is:` 后面一大段 HOB 转储；`GCD - After memory init:` | 库 | `init_memory` |
| 4851 ~ 4905 | `Registering platform components` / `Registering default components` / `Initializing System Table` / `Parsing HOB list for Guided HOBs.` / `Installing Firmware Volumes from HOB list.` 每段后跟 `Finished.` | 库 | `lib.rs::start_dispatcher` |
| 4906 | `Dispatching Drivers` | 库 | `start_dispatcher` → `core_dispatcher` |
| 4907 ~ 4932 | `Dispatching patina_dxe_core::cpu::cpu_arch_protocol::CpuArchProtocolInstaller` … `Dispatching patina_test::component::TestRunner` | 组件分发器 | `component_dispatcher.rs::dispatch` |
| 4933 ~ 6558 | 125 次 `Loading driver at` / `Loaded image at`，夹着各 C 驱动自己的输出 | PI 分发器 + C 驱动 | `pi_dispatcher.rs::dispatch` |
| 6559 | `Finished Dispatching Drivers` | 库 | `start_dispatcher` |
| 6560 ~ 6565 | `Components not dispatched:` 表格 | 库 | `component_dispatcher.rs::display_not_dispatched` |
| 6567 | `[Bds] Entry...` | **C 代码**（BDS 驱动） | `lib.rs::call_bds` 跳过去的 |
| 6948 | `Patina on-system unit-test result totals: 27 passes, 0 fails` | `patina_test` | 在 ReadyToBoot 事件上跑 |
| 8290 | `Loaded image ... Shell.efi` | PI 镜像加载 | `pi_dispatcher/image.rs` |
| 8308 | `DXE ResetSystem2: ResetType Shutdown` | C 的 ResetSystem 运行时驱动 | `startup.nsh` 里的 `reset -s` |

这张表就是全书的地图。每一行你都应该能用 `grep -n` 自己找到。

### 2.3 读懂三种"没分发"

第 6560 行的表格是最有信息量的几行：

```
Components not dispatched:
name                                                    error message
patina_performance::component::performance::Performance patina::component::service::Service<dyn ...PerformanceManager> not available.
Driver PrintScreenLogger (EA205B85-...) found but not dispatched.
Driver DisplayEngine (C09E4CE4-...) found but not dispatched.
```

- 第一条是 **Rust 组件**没分发：它要的 `Service<dyn PerformanceManager>` 没人生产。第 4 章解释这个机制。性能跟踪默认关闭（`BLD_*_PERF_TRACE_ENABLE=FALSE`），所以这是预期行为。
- 后两条是 **C 驱动**没分发：depex 不满足，和 Tiano 的行为一样。无头模式没有显示设备，`DisplayEngine` 依赖的协议没出现。带窗口跑一次（`-RunOnly` 不加 `-Headless`），这两条会消失。片上测试的总数（27、32 等）会随配置和时序变化，不要拿它当回归指标，看 `0 fails` 就够了。

另外注意：如果某个架构协议缺失，这里还会出现 `Missing architectural protocol: ..., "Timer"` 之类的行，来自 `lib.rs::core_display_missing_arch_protocols`。本次日志里没有，说明 13 个架构协议齐全。

### 2.4 日志级别和过滤

`q35_dxe_core.rs` 里的 `static LOGGER` 定义了全局级别 `Info` 和一组按 target 关闭的噪音源（`goblin`、`gcd_measure`、`allocations`、`efi_memory_map`……）。想看 GCD 每次分配，把 `allocations` 那行删掉重编即可。Rust 的 `log::debug!`/`log::trace!` 宏在 release 构建里会被 `release_max_level_info` feature 直接编译掉，这是 `Cargo.toml` 里 `log` 依赖的 feature。

### 检查点

- 哪一行之前是 C，之后是 Rust？（4231）
- `Finished Dispatching Drivers` 之后还有大量 C 驱动输出，它们是谁分发的？（BDS 阶段 `ConnectController` 触发的 UEFI 驱动模型，不是 DXE 分发器）
- **日志证据**：带窗口跑一次，确认 `DisplayEngine` 从"未分发"表里消失。

---

## 3. DXE Core 入口与内存初始化

### 这章解决什么问题

从 `efi_main` 开始，一行一行跟到分发器启动。重点是内存：GCD 怎么从 HOB 建起来、什么时候才能用堆、HOB 为什么要搬家。

### 3.1 平台 binary 的入口（`bin/q35_dxe_core.rs`）

```rust
static CORE: Core<Q35> = Core::new(CompositeSectionExtractor::new());

#[cfg_attr(target_os = "uefi", unsafe(export_name = "efi_main"))]
pub unsafe extern "efiapi" fn _start(physical_hob_list: *const c_void) -> ! {
    log::set_logger(&LOGGER).map(|()| log::set_max_level(log::LevelFilter::Trace)).unwrap();
    unsafe { LOGGER.init(physical_hob_list).unwrap(); }
    log::info!("DXE Core Platform Binary v{}", env!("CARGO_PKG_VERSION"));
    CORE.entry_point(physical_hob_list)
}
```

> **Rust 概念**：`static CORE` 是一个编译期构造的全局对象，`Core::new` 是 `const fn`，所以不需要运行时初始化，也不需要堆。`extern "efiapi"` 等价于 C 里的 `EFIAPI` 调用约定。`-> !` 表示永不返回，和 Tiano DxeCore 的 `DxeMain` 一样。`unsafe` 标在函数上，是在告诉调用方"我无法验证这个指针"。

对比 C：`DxeMain(VOID *HobStart)`。参数一样，职责一样。

### 3.2 `Core::entry_point`（`patina_dxe_core/src/lib.rs`）

```rust
pub fn entry_point(&'static self, physical_hob_list: *const c_void) -> ! {
    assert!(self.set_instance(), "DXE Core instance was already set!");
    assert!(!physical_hob_list.is_null(), ...);
    let relocated_hob_list = self.init_memory(physical_hob_list);
    if let Err(err) = self.start_dispatcher(relocated_hob_list) {
        log::error!("DXE Core failed to start: {err}");
    }
    call_bds();
}
```

三步：建内存、跑分发、跳 BDS。`set_instance` 把 `&'static self` 的地址存进一个 `Once`，供那些没有 `self` 可拿的 `extern "efiapi"` 回调（Boot Services 表里的函数指针）反查核心对象。

### 3.3 `init_memory`：从"不能分配"到"可以分配"

按源码顺序（`lib.rs` 第 411 行起）：

1. `cpu::initialize_cpu_subsystem(P::CpuInfo::exception_handlers())`：装 IDT/异常处理。平台可以通过 `CpuInfo` trait 注入自己的异常处理函数。
2. `gcd::init_gcd(physical_hob_list)`：**只用 HOB 里的内存资源描述符**，在 GCD 里标出一块已知空闲的系统内存。注释写得很直白：这一步之后 Rust 堆才可用。GCD 本身（`gcd/spin_locked_gcd.rs`）在初始化前用的是一块静态数组，不依赖堆。
3. `hob_list.discover_hobs(physical_hob_list)`：把 PI 格式的 HOB 列表解析成 Rust 的 `HobList`（`patina::pi::hob`），并打印 `HOB list discovered is:`。
4. `PROTOCOL_DB.init_protocol_db()`：协议数据库建好几个固定句柄。
5. `allocator::init_memory_support(&hob_list)`：处理 memory allocation HOB 和 memory bin（预留给特定内存类型的区域，见 Patina 文档书 `dxe_core/memory_bins.md`），分配器全功能上线。
6. **搬两份 HOB**：一份按 PI 原始字节 `Box::leak` 出去，给 C 驱动的 `HobLib` 用（它们还要靠 `gEfiHobListGuid` 配置表找 HOB）；一份是 Rust `HobList`，`relocate_hobs()` 后存进 `self.hob_list`。为什么要搬：PEI 给的 HOB 可能不在已映射内存里，而且初始空闲区可能装不下。
7. 调试器初始化、性能计时器频率（`P::CpuInfo::perf_timer_frequency()`，Q35 用 ACPI PM Timer 校准 TSC）。
8. 往组件存储里塞四个核心 Service：`DxeInterruptManager`、`CoreMemoryManager`、`CoreDxeDispatch`、`PerfTimer`。第 4 章会看到 Service 是什么。
9. 打印 `GCD - After memory init:`（日志第 4790 行）。

> **Rust 概念**：`Box::leak` 把一块堆分配变成 `'static` 引用，故意"泄漏"，等价于 C 里 `AllocatePool` 之后永不 `FreePool`。DXE 阶段很多东西就该活到 ExitBootServices，这是合理用法。`Once` 是"只能写一次"的容器，替代 C 里的全局指针加 `if (x == NULL)`。

### 3.4 内存保护

`init_memory` 之后，GCD 和分页子系统（`gcd/spin_locked_gcd/paging.rs`，底层是 `patina_paging` crate）一起维护页表。日志里大量 `Applying image memory protections on 0x... with attributes 0x...` 就是镜像加载时按节属性设 NX/RO。两个相关 feature（`patina_dxe_core/Cargo.toml`）：

- `compatibility_mode_allowed`：允许对不满足保护要求的旧镜像（典型是老的 OS loader）退回兼容模式。`patina-dxe-core-qemu` 默认打开。
- `v1_resource_descriptor_support`：接受老格式的资源描述 HOB。OVMF 目标打开，Q35 不开，因为 Q35 的 PEI 已经产 v2 HOB。

### 检查点

- 堆什么时候可用？（`init_gcd` 之后）
- 为什么 HOB 要复制两份？（C 驱动要 PI 原始布局，Rust 组件要解析后的 `HobList`）
- **日志证据**：找到 `HOB list discovered is:` 之后第一个 `ResourceDescriptor` 的 `physical_start`，再在 `GCD - After memory init:` 的表里找到同一地址。

---

## 4. 组件模型与依赖注入

### 这章解决什么问题

Patina 组件长什么样、和 C 驱动哪里不同、分发顺序谁决定。读完能看懂 `bin/q35_dxe_core.rs` 里 `ComponentInfo` 那一坨注册代码。

### 4.1 和 C 驱动的根本区别

| | C DXE 驱动 | Patina 组件 |
| --- | --- | --- |
| 打包 | 独立 `.efi`，放 FV | 和核心静态链接进同一个二进制 |
| 依赖声明 | INF 里的 `[Depex]`，按协议 GUID | 入口函数的**参数类型** |
| 入口 | `EFI_STATUS EFIAPI Entry(ImageHandle, SystemTable)` | `fn entry_point(self, 参数…) -> Result<()>` |
| 拿依赖 | `gBS->LocateProtocol` 自己去找 | 框架按参数类型注入 |
| 发布接口 | `InstallProtocolInterface` + 裸指针 | `Service<dyn Trait>`，类型安全 |
| 失败 | 返回错误码，可能被反复重试 | 返回 `Err`，记录后不再重试 |

核心思想借自游戏引擎 Bevy 的 ECS（`patina/src/component.rs` 开头的文档明说了）：**组件声明它要什么，框架负责在条件满足时调用它**。

### 4.2 最小组件

```rust
use patina::{component::component, error::Result};

pub struct HelloStruct(pub &'static str);

#[component]
impl HelloStruct {
    fn entry_point(self, age: Config<i32>) -> Result<()> {
        log::info!("Hello, {}! You are age {}!", self.0, *age);
        Ok(())
    }
}
```

（这是 `patina_samples/src/component/hello_world.rs` 的原文。）

规则：

- `#[component]` 属性宏贴在 `impl` 块上，块里**必须**有名为 `entry_point` 的方法。宏会生成 `IntoComponent` 实现，并在编译期检查参数冲突。
- 第一个参数是 `self`（消费掉自己，常见）或 `&self`/`&mut self`。
- 其余参数（最多 5 个，不够用元组打包）每个都得实现 `Param` trait。

> **Rust 概念**：`#[component]` 是过程宏，相当于一个在编译期跑的代码生成器，定义在 `patina_macro` crate。`self` 按值传入意味着组件对象在分发后就被消耗，所以组件天然"只跑一次"。

### 4.3 参数类型就是依赖

`patina/src/component.rs` 的表格，按你会用到的频率排：

| 参数 | 含义 | 满足条件 |
| --- | --- | --- |
| `Config<T>` | 只读配置 | 该类型的配置已**锁定** |
| `ConfigMut<T>` | 可写配置 | 该类型的配置**未锁定** |
| `Service<dyn Trait>` | 别人提供的接口 | 有人已经 `add_service` |
| `Hob<T>` | 解析后的 GUID HOB（可多个，`iter()`） | HOB 列表里存在该 GUID |
| `Commands` | 延迟操作队列：`add_config`、`add_service` | 总是满足 |
| `&mut Storage` / `&Storage` | 直接操作存储（不推荐，容易冲突） | 总是满足 |
| `StandardBootServices` | Rust 版 Boot Services | 总是满足 |
| `Option<P>` | 包一层：条件不满足也跑，拿到 `None` | 总是满足 |

**Config 的锁定规则**（`params.rs` 文档）：平台在 `ComponentInfo::configs` 里 `add.config(x)` 注册的配置默认是锁定的；如果有组件声明了 `ConfigMut<T>`，框架会把它解锁，所有想改的组件跑完后（显式 `lock()` 或框架在没人能再跑时自动锁），要 `Config<T>` 的组件才会被分发。Q35 的 `MmConfigurationProvider` 就是典型：它拿 `Hob<MmCommRegionHob>` 和 `ConfigMut<MmCommunicationConfiguration>`，把运行时探测到的 ACPI 基址填进配置，之后 `SwMmiManager`、`MmCommunicator` 才能用 `Config<MmCommunicationConfiguration>` 启动。

### 4.4 分发顺序由谁决定

`patina_dxe_core/src/component_dispatcher.rs::dispatch`：

```rust
self.components.retain_mut(|component| {
    !match component.run(&mut self.storage) {
        Ok(true)  => true,   // 依赖满足，已执行，移出队列
        Ok(false) => false,  // 依赖不满足，留在队列
        Err(err)  => { log_debug_assert!(...); true } // 执行失败，也移出，不重试
    }
});
```

外层 `lib.rs::core_dispatcher` 的循环：

```rust
loop {
    let dispatched = self.component_dispatcher.lock().dispatch();     // 先 Rust 组件
    let dispatched = dispatched || self.pi_dispatcher.dispatch()?;     // 再 C 驱动
    if !dispatched { break; }
}
```

`start_dispatcher` 调两次 `core_dispatcher`，中间 `lock_configs()`。所以完整语义是：

1. 反复分发，直到一轮里 Rust 组件和 C 驱动都没有新的能跑。
2. 锁定所有还没锁的配置。
3. 再反复分发（这时等 `Config<T>` 的组件可以跑了）。
4. 打印没分发的。

组件之间**没有显式顺序**。`ComponentInfo::components` 里 `add.component` 的先后只影响同一轮内的尝试顺序；真正的依赖由参数类型表达。这就是第 5 章练习里"消费者先注册也没关系"的原因。

### 4.5 Service：Rust 版的协议

```rust
trait MyService { fn do_it(&self); }

#[derive(IntoService)]
#[service(dyn MyService)]
struct MyServiceImpl;
impl MyService for MyServiceImpl { fn do_it(&self) {} }

// 生产者
fn producer(mut commands: Commands) -> Result<()> { commands.add_service(MyServiceImpl); Ok(()) }
// 消费者：直到有人生产才会被分发
fn consumer(s: Service<dyn MyService>) -> Result<()> { s.do_it(); Ok(()) }
```

要点（`service.rs` 文档）：服务一旦注册就是 `'static` 且只读，方法只能 `&self`，要可变状态就用内部可变性（`RefCell`、`spin::Mutex`、原子类型）。一个服务可以在构造时持有另一个 `Service<dyn X>`，框架保证顺序。

> **Rust 概念**：`dyn Trait` 是 trait 对象，相当于 C 里"一张函数指针表加一个 this 指针"，只不过编译器替你生成表。`#[derive(IntoService)]` 让 `GreetingImpl` 以 `dyn Greeting` 的身份进入存储。

### 4.6 Hob：声明式解析 GUID HOB

```rust
#[derive(FromHob, Default, Clone, Copy, zerocopy::FromBytes)]
#[hob = "d4ffc718-fb82-4274-9afc-aa8b1eef5293"]
#[repr(C)]
pub struct MmCommRegionHob { buffer_type: u64, address: u64, pages: u64 }
```

`#[repr(C)]` 保证和 C 结构体布局一致；`zerocopy::FromBytes` 允许从字节直接转型而不复制；`#[hob = "..."]` 给出 GUID。复杂布局手动 `impl FromHob` 写 `parse`。`start_dispatcher` 里的 `insert_hobs` 一次性把所有 GUID HOB 解析进存储，日志里那串 `No parser registered for HOB: GuidHob { ... }` 警告就是"没有任何组件声明过这个 GUID"。

### 检查点

- 一个组件要 `Config<T>`，但平台没注册 T，它会怎样？（永远不分发，最后出现在"未分发"表里）
- `add.component` 的顺序决定执行顺序吗？（不决定）
- **日志证据**：第 4916 行 `MmConfigurationProvider` 在 4921 行 `SwMmiManager` 之前。改 `bin/q35_dxe_core.rs` 把两者注册顺序对调，重跑，顺序不变。

---

## 5. 动手写第一个组件

### 这章解决什么问题

把第 4 章的概念落到一个能跑、能在日志里看见的组件上。完整代码在本仓库 `examples/hello_component/`，这里讲每一段为什么这么写。

### 5.1 目标

两个组件、一个服务、一个配置：

- `HelloGreeter`：带状态（名字），读 `Config<GreetingConfig>`，生产 `Service<dyn Greeting>`。
- `GreetingConsumer`：消费 `Service<dyn Greeting>`。
- 故意**先注册消费者**，验证框架按依赖排序。

### 5.2 代码走读（`examples/hello_component/src/lib.rs`）

**crate 骨架**

```rust
#![no_std]
extern crate alloc;
use alloc::{format, string::String};
```

> **Rust 概念**：固件里没有操作系统，所以 `#![no_std]` 去掉标准库，只剩 `core`（无堆）和 `alloc`（有堆，Patina 的分配器在 `init_gcd` 之后就位）。`String`、`Vec`、`Box` 都来自 `alloc`。

**配置类型**

```rust
#[derive(Debug, Default, Clone, Copy)]
pub struct GreetingConfig { pub exclamation_marks: usize }
```

`Config<T>` 要求 `T: Default`，所以必须 `derive(Default)`。

**服务接口和实现**

```rust
pub trait Greeting { fn greeting(&self) -> String; }

#[derive(IntoService)]
#[service(dyn Greeting)]
struct GreetingImpl { text: String }
impl Greeting for GreetingImpl { fn greeting(&self) -> String { self.text.clone() } }
```

`GreetingImpl` 是私有的，外界只认 `dyn Greeting`。这正是"接口与实现分离"。

**生产者**

```rust
#[component]
impl HelloGreeter {
    fn entry_point(self, cfg: Config<GreetingConfig>, mut commands: Commands) -> Result<()> {
        let marks = "!".repeat(cfg.exclamation_marks);
        let text = format!("Hello, {}{}", self.name, marks);
        log::info!("[hello_component] {text}  (config says {} exclamation marks)", cfg.exclamation_marks);
        commands.add_service(GreetingImpl { text });
        Ok(())
    }
}
```

用 `Commands` 而不是 `&mut Storage`：`params.rs` 文档明确说 `&mut Storage` 和 `Config<T>` 同时出现会冲突（你可能在读配置的同时改存储），`Commands` 把结构性修改推迟到入口返回之后。

**消费者**

```rust
#[component]
impl GreetingConsumer {
    fn entry_point(self, greeting: Service<dyn Greeting>) -> Result<()> {
        log::info!("[hello_component] consumer got: {}", greeting.greeting());
        Ok(())
    }
}
```

### 5.3 接进平台

`examples/hello_component/apply.ps1` 做两处改动（手改也行）：

1. `patina-dxe-core-qemu/Cargo.toml` 的 `[dependencies]` 里加 `hello_component = { path = "../examples/hello_component" }`。
2. `bin/q35_dxe_core.rs`：
   - `fn configs` 里加 `add.config(hello_component::GreetingConfig { exclamation_marks: 3 });`
   - `fn components` 里在 `AdvancedLoggerComponent` 之后加两行 `add.component(...)`，消费者在前。

为什么放在 AdvancedLogger 之后：组件在分发时才输出日志，而 `LOGGER` 在 `_start` 里已经 `set_logger`，所以其实放哪都能打印；放后面只是让日志顺序更自然。

### 5.4 编译、运行、验证

```powershell
.\examples\hello_component\apply.ps1
.\build_q35.ps1 -LocalCore -Headless -Run > hello.log 2>&1
Select-String -Path hello.log -Pattern "hello_component"
```

预期四行，顺序固定（实际记录见 `logs/qemu_q35_hello_component.log` 第 4919 到 4939 行）：

```
Dispatching hello_component::HelloGreeter
[hello_component] Hello, Patina learner!!!  (config says 3 exclamation marks)
Dispatching hello_component::GreetingConsumer
[hello_component] consumer got: Hello, Patina learner!!!
```

消费者虽然先注册，但第一轮 `run` 返回 `Ok(false)`（服务不存在），留在队列；生产者跑完，`Commands` 把服务写入存储；下一轮消费者才跑。记录的日志里两者之间还隔着十几个其他组件的分发。

验证完想恢复上游文件：`.\examples\hello_component\apply.ps1 -Revert`。

### 5.5 练习

1. 把 `GreetingConsumer` 的参数改成 `Option<Service<dyn Greeting>>`，再把 `HelloGreeter` 的注册注释掉。观察消费者仍然运行、打印 `None` 分支。
2. 加一个 `ConfigMut<GreetingConfig>` 的组件把 `exclamation_marks` 改成 10，看 `HelloGreeter` 读到的值。理解锁定时机：它在你的组件跑完、配置被锁之后才分发。
3. 把 `entry_point` 改成返回 `Err(patina::error::EfiError::DeviceError)`，看日志里 `Dispatched: ... Status = [Failed]`，以及它不再重试。
4. 片上测试（已做好，在 `src/lib.rs` 的 `mod tests`）：两个 `#[patina_test]`，一个断言 `Service<dyn Greeting>` 存在且含注册的名字，一个同时注入 `Config<GreetingConfig>` 断言感叹号数量和配置一致。要点：测试函数和组件一样靠参数类型注入依赖；`#[on(event = BinaryGuid(efi::EVENT_GROUP_READY_TO_BOOT))]` 让它们在所有组件和驱动分发完之后才跑，所以服务一定已经存在；断言用 `u_assert!`/`u_assert_eq!`，失败返回错误字符串而不是 panic。在 `Patina on-system unit-test results` 里找 `hello_component::tests::greeting_service_exists ... ok` 和 `greeting_matches_config ... ok`。练习：把 `apply.ps1` 里的 `exclamation_marks` 改成 5 再跑，两个测试都应仍然通过；再把测试里的期望改成固定值 3，看失败时日志长什么样、`exit_on_patina_test_failure` 如何让 QEMU 以非零码退出。

### 检查点

- 为什么用 `Commands` 不用 `&mut Storage`？
- 消费者先注册为什么不会先跑？
- **日志证据**：你自己的 `hello.log` 里四行输出顺序和上面一致。

---

## 6. 与 C 世界互操作

### 这章解决什么问题

你的平台上 95% 的驱动还是 C。这章讲 Patina 怎么加载它们、Rust 组件怎么调 C 协议、C 驱动怎么用 Rust 发布的东西。

### 6.1 Patina 怎么跑 C 驱动

`patina_dxe_core/src/pi_dispatcher.rs`：

- `install_firmware_volumes_from_hoblist`：遍历 FV HOB，对每个 FV 安装 `FirmwareVolumeBlock` 和 `FirmwareVolume2` 协议（日志 4898 行之后的三对 `InstallProtocolInterface`）。
- `dispatch`：扫描 FV 里的 FFS 文件，读 depex 段，用协议数据库评估，满足的按 PE32 加载（`pi_dispatcher/image.rs`，用 `goblin` crate 解析 PE/COFF，自己做重定位）并调用入口。嵌套 FV、压缩段（`section_decompress.rs`，通过 `P::Extractor` 即 `CompositeSectionExtractor` 支持 Brotli/LZMA/Tiano 等）都处理。
- `schedule`/`trust`：实现 DXE Services 里的 `Schedule`、`Trust`，给 `SecurityArch` 协议用。

这段逻辑和 Tiano `DxeCore/Dispatcher` 是对等实现，日志里 `Loading driver at 0x... EntryPoint=0x... XXX.efi` 的格式也故意保持一致，方便 WinDbg 符号脚本。

### 6.2 Boot Services 的 Rust 实现

C 驱动拿到的 `gBS` 指向 `patina_dxe_core/src/systemtables.rs` 构造的表，表里每个函数指针都是 `extern "efiapi" fn`，分布在 `protocols.rs`（Install/Locate/Open/Close…）、`events.rs`（CreateEvent/SignalEvent/TPL）、`memory_manager.rs`（AllocatePages/Pool）、`driver_services.rs`（Connect/Disconnect/LoadImage/StartImage）、`misc_boot_services.rs`。

进入这些函数时没有 `self`，所以它们通过第 3 章说的 `__SELF` 和全局 `PROTOCOL_DB`、`GCD`、`EVENT_DB` 工作。全局状态用 `TplMutex`（`tpl_mutex.rs`）保护：加锁等价于 `RaiseTPL`，解锁等价于 `RestoreTPL`，和 C 核心的 `CoreAcquireLock` 语义相同。

### 6.3 Rust 组件调 C 协议

组件参数里声明 `StandardBootServices`（`patina/src/uefi/boot_services.rs`），它提供 `locate_protocol`、`install_protocol_interface`、`create_event`、`handle_protocol` 等方法的 Rust 封装，返回 `Result` 而不是 `EFI_STATUS`。协议结构体定义在 `patina::pi::protocol` 和 `patina::standard::efi::protocols`（来自 `r-efi` crate）。调用 C 函数指针仍然是 `unsafe`，封装只是把"检查 NULL、转换错误码"做掉了。

`patina::uefi::boot_services::protocol_handler` 和 `boxed` 两个子模块是进阶：前者把"注册协议通知"包装成安全接口，后者给 `AllocatePool` 的内存套上 `Box`，自动释放。

### 6.4 让 C 驱动用 Rust 发布的协议

两条路：

1. **直接装协议。** 在组件里用 `StandardBootServices::install_protocol_interface`，传 `#[repr(C)]` 的结构体和 `extern "efiapi"` 函数。本质上就是在 Rust 里写 C ABI。Patina 自己的 `CpuArchProtocolInstaller`、`DecompressProtocolInstaller` 就是这么做的（`cpu/cpu_arch_protocol.rs`、`decompress.rs`）。
2. **Service 同时发布为协议。** `IntoService` 派生宏支持把服务注册为 EDK II 协议（`service.rs` 文档"Protocol Backwards Compatability"一节），但文档反复强调"仅为兼容，能不用就不用"。

反过来的方向（Rust 消费 C 协议）优先用 `StandardBootServices`，别把 C 协议再包成 Service，除非你打算以后把那个 C 驱动也换成 Rust。

### 6.5 架构协议清单

`lib.rs` 里 `ARCH_PROTOCOLS` 列了 13 个（Security、Cpu、Metronome、Timer、Bds、Watchdog、Runtime、Variable、Variable Write、Capsule、Monotonic Counter、Reset、Real Time Clock）。分发结束后核心逐个 `locate_protocol`，缺的打 `Missing architectural protocol` 警告。Q35 上 Cpu 由 Rust 组件提供，其余由 C 驱动提供。移植时这是第一张要核对的清单。

### 检查点

- `gBS->LocateProtocol` 在 Rust 里由哪个文件实现？（`protocols.rs`）
- Rust 组件之间通信该用 Service 还是协议？（Service）
- **日志证据**：找到 `installed EFI_CPU_ARCH_PROTOCOL_GUID`（4909 行），确认它在任何 `Loading driver at` 之前，说明 C 驱动一开始分发时 Cpu 架构协议已经在了。

---

## 7. 调试

### 这章解决什么问题

panic 长什么样、怎么挂调试器、怎么把日志调细。

### 7.1 panic 和 assert

`bin/q35_dxe_core.rs` 的 `#[panic_handler]`：打印 panic 信息、`StackTrace::dump()` 打栈、`patina_debugger::breakpoint()`、最后 `qemu_fail()` 通过 `isa-debug-exit` 设备让 QEMU 以非零码退出。所以 CI 里 panic 等价于测试失败。

Rust 的 `assert!`、数组越界、整数溢出（debug 构建）、`unwrap()` 遇到 `None`/`Err` 都会走到这里。这和 C 里 `ASSERT` 后继续跑或者悄悄写坏内存是本质区别：**Patina 宁可停机也不带病运行**。

核心代码里还有 `log_debug_assert!`（`patina` crate）：debug 构建 panic，release 构建只记日志。`component_dispatcher.rs` 对组件返回 `Err` 的处理就用它。

### 7.2 软件调试器（patina_debugger）

`patina_debugger` 在异常处理里挂一个 GDB 远程协议的 stub，走串口。Q35 平台用 COM1（0x3F8）：

```rust
static DEBUGGER: PatinaDebugger<Uart16550> =
    PatinaDebugger::new(unsafe { Uart16550::new_io(0x3F8) })
        .with_force_enable(_ENABLE_DEBUGGER)
        .with_log_policy(DebuggerLoggingPolicy::FullLogging);
```

两个 cargo feature：`build_debugger` 把它编进去（debug 构建默认开），`enable_debugger` 让它启动时就停在初始断点。构建命令：

```powershell
cd patina-dxe-core-qemu
cargo make q35 --features enable_debugger
```

QEMU 侧要把 COM1 暴露成 TCP：`stuart_build ... SERIAL_PORT=50001 --FlashOnly`（patina-qemu 的 `build_and_run_rust_binary.py` 默认就是 50001）。本仓库的脚本把这两步合成一条：`.\build_q35.ps1 -EnableDebugger -Run -SerialPort 50001 -GdbServer 5555`（`-GdbServer` 对应 7.3 节的 `GDB_SERVER`）。然后用 GDB 连 `target remote :50001`，或者按 `patina-qemu/docs/src/debugging/windbg_uefi.md` 用 WinDbg 加 EXDi 插件（来自 microsoft/uefi_debug_tools）。调试器还支持自定义 monitor 命令（`add_monitor_command`）和 `debugger_reload` feature（不重启 QEMU 就换一个新编的 DXE Core 镜像，见文档书 `dev/debugging/core_reload.md`）。

### 7.3 硬件级调试

`stuart_build ... GDB_SERVER=5555` 打开 QEMU 自带的 gdbstub，和上面的软件调试器互补：软件调试器看得到 Rust 符号和模块加载事件（`notify_module_load`），QEMU gdbstub 能在固件自己都挂了的时候看寄存器。

符号：`cargo make q35` 产出同名 `.pdb`（`Makefile.toml` 里 `-C link-arg=/PDBALTPATH:qemu_q35_dxe_core.pdb`），C 驱动的 PDB 在 `Build/.../PDB/`，`stuart_build` 结束时的 `Copying Symbols to flat directory` 就是在集中它们。

### 7.4 把日志调细

- 全局级别：`q35_dxe_core.rs` 的 `LOGGER` 第三个参数。
- 按 target：`TargetFilter` 列表。target 默认是模块路径，所以 `TargetFilter { target: "hello_component", log_level: Trace, .. }` 只放开你自己的 crate。
- release 构建受 `log` crate 的 `release_max_level_info` 限制，`debug!`/`trace!` 直接不存在。

### 检查点

- debug 构建里 `unwrap()` 失败会怎样？（panic → 栈回溯 → QEMU 退出）
- `build_debugger` 和 `enable_debugger` 的区别？
- **日志证据**：在 `patina_test` 的回调里（`bin/q35_dxe_core.rs` 里 `with_callback`）看到失败时调用 `qemu_fail()`，理解 `exit_on_patina_test_failure` feature 的作用。

---

## 8. 从 QEMU 到自己的平台

### 这章解决什么问题

把 `patina-dxe-core-qemu` 复制成你自己的平台 crate，要改什么、PEI 侧要给什么、EDK II 侧要改什么。官方清单在文档书 `integrate/patina_dxe_core_requirements_checklist.md`，这里按动手顺序重排。

### 8.1 Rust 侧：实现四个 trait

`patina_dxe_core/src/lib.rs` 的 `PlatformInfo`：

```rust
pub trait PlatformInfo: 'static {
    type MemoryInfo: MemoryInfo;
    type CpuInfo: CpuInfo;
    type ComponentInfo: ComponentInfo;
    type Extractor: SectionExtractor;
    const DEFAULT_PERFORMANCE_CONFIG: PerformanceConfig = PerformanceConfig::new();
}
```

| trait | 要实现什么 | Q35 怎么做 |
| --- | --- | --- |
| `MemoryInfo` | 只有 `prioritize_32_bit_memory()`，默认 false | 用默认 |
| `CpuInfo` | `perf_timer_frequency()`、`exception_handlers()`；AArch64 还要 `gic_bases()` | 用 PM Timer 校准 TSC |
| `ComponentInfo` | `configs`、`components`、`services` 三个注册回调 | 注册 MM、SMBIOS、ACPI、日志、测试组件 |
| `Extractor` | 段解压器 | `CompositeSectionExtractor`（全家桶） |

> **Rust 概念**：trait 里的 `type X: Bound` 叫关联类型，相当于"这个 trait 的实现者必须指定一个满足 Bound 的类型"。`Core<P: PlatformInfo>` 是泛型，编译期单态化，没有运行时开销，所以平台配置是零成本的。

然后：

- 选日志后端。Q35 用 `AdvancedLogger<Uart16550>` 走 I/O 端口；MMIO 串口用 `Uart16550::new_mmio` 或 `UartPl011`（`patina::peripheral::serial`）。
- 选调试器串口。
- 写 `panic_handler`。QEMU 的 `qemu_fail` 换成你的平台复位或死循环。
- 架构：`Cargo.toml` 的 `x64`/`aarch64` feature 和 `Makefile.toml` 的 target。AArch64 还需要 `CpuInfo::gic_bases()`。

### 8.2 PEI 侧：必须交付的 HOB

Patina 不读 PCD，不读 DSC，一切来自 HOB：

- **Resource Descriptor HOB v2**（带缓存属性）描述所有系统内存和 MMIO。老平台只产 v1 时打开 `v1_resource_descriptor_support`。
- **Memory Allocation HOB**：PEI 已占用的区域，包括 DXE Core 自己的栈和镜像。
- **FV HOB**：至少一个包含 DXE 驱动的 FV。
- **Firmware Volume Info HOB**、**CPU HOB**（地址/IO 位宽）。
- 平台自定义 GUID HOB：Q35 用 `MmCommRegionHob` 传 MM 通信缓冲区，用性能配置 HOB 控制性能跟踪。你的平台用 `Hob<T>` 参数接收自己的。

验证工具：`patina-qemu` 的 extdep 里有 `patina_readiness_tool`（`READINESS.QEMU_ext_dep.json`），它是一个在现有 C 固件上运行的 DXE 驱动，检查 HOB 列表和平台是否满足 Patina 的要求，移植前先跑它。

### 8.3 EDK II 侧

1. 从 DSC 里删掉 `MdeModulePkg/Core/Dxe/DxeMain.inf`、`CpuDxe`、`RuntimeDxe`（Patina 内置了后两者的功能）。
2. FDF 里照抄 `QemuQ35Pkg.fdf` 的 `[FV.RUST_DXE_CORE]` 段：`FILE DXE_CORE = <GUID> { SECTION PE32 = <你的.efi> }`。`DXE_CORE_BINARY_OVERRIDE` 这种命令行覆盖变量值得保留，方便 CI 换二进制。
3. 保证 PEI 的 `DxeIpl` 能在 FV 里找到 `EFI_FV_FILETYPE_DXE_CORE` 类型的文件。Q35 把它放在单独的 FV 是为了支持"编译后替换 DXE Core"。
4. 逐步把 C 驱动换成 Rust 组件：先换纯软件的（SMBIOS、ACPI 表生成、性能记录），再换硬件相关的。每换一个，用第 2 章的日志表核对架构协议仍然齐全。

### 8.4 一个移植检查单

- [ ] `PlatformInfo` 四个关联类型都实现
- [ ] 串口日志能在 `_start` 第一行就输出
- [ ] HOB 里有 v2 资源描述符，或开了 v1 feature
- [ ] 13 个架构协议分发后全部存在（看 `Missing architectural protocol` 警告）
- [ ] `Components not dispatched` 表里没有意料之外的项
- [ ] BDS 能进入；`patina_readiness_tool` 通过
- [ ] 跑通 `patina_test`（第 9 章）

### 检查点

- 你的平台有哪些信息现在是 PCD、需要改成 HOB？
- `Extractor` 选错会有什么现象？（压缩段解不开，驱动"found but not dispatched"或加载失败）
- **日志证据**：日志第 4860 行后的 `No parser registered for HOB` 列表就是你的平台会发给 Patina、但没人消费的 GUID HOB，逐个判断是否需要写 `FromHob`。

---

## 9. 跟上游一起演进

### 9.1 版本策略

- `patina-dxe-core-qemu/Cargo.toml` 用 `patina = { version = "23" }` 这种主版本锁定，`Cargo.lock` 钉具体版本。升级 = 改主版本号 + `cargo update`。
- Rust 版本由 `rust-toolchain.toml` 钉死（当前 1.95.0），`[tools]` 段钉 cargo-make 等工具版本。`setup.ps1` 就是读这个文件装的。
- 主版本跳得快（11 → 13 → 23），每次跳主版本看上游 release notes 里的 breaking changes。

### 9.2 对着本地 patina 源码改

```powershell
git clone https://github.com/OpenDevicePartnership/patina D:\src\patina
cd patina-dxe-core-qemu
cargo make q35 -- --crate-patch D:\src\patina --leave-patch
```

`--crate-patch` 往 `Cargo.toml` 里写 `[patch.crates-io]`，让所有 `patina_*` 依赖指向本地路径；不加 `--leave-patch` 时构建完自动撤销。这是贡献上游时的标准工作流：改 `patina`、在 QEMU 上验证、提 PR。

### 9.3 三层测试

| 层 | 命令 | 在哪跑 | 用途 |
| --- | --- | --- | --- |
| 单元测试 | `cargo make test`（patina 仓库） | 主机，`std` feature | 纯逻辑：GCD 合并、协议数据库、HOB 解析，大量 `mockall` mock |
| 片上测试 | `#[patina_test]` + `TestRunner` 组件 | QEMU 里 | 审计启动后状态，例如 `gcd_free_memory_merged_test` |
| 平台 CI | `patina-qemu` 的 `platform-ci.yml` / `nightly-os-boot.yml` | GitHub Actions | 启动到 Shell、启动 Ubuntu/Windows |

片上测试写法（`patina_dxe_core/src/core_patina_tests/audit_tests.rs`）：

```rust
#[patina_test]
#[on(event = BinaryGuid(efi::EVENT_GROUP_READY_TO_BOOT))]
fn gcd_free_memory_merged_test() -> patina_test::error::Result {
    ...
    u_assert!(cond, "Found adjacent free memory descriptors");
    Ok(())
}
```

`#[on(event = ...)]` 指定在哪个事件组触发，没有就在 `TestRunner` 分发时立即跑。`TestRunner::default().with_filter(Filter::include("x64"))` 可以按名字筛选。测试结果以 JSON 打到日志（`patina_on_system_unit_test_results`），CI 从中解析。

### 9.4 社区

- 文档书：<https://opendevicepartnership.github.io/patina/>，章节对应关系见本文各处引用的路径。
- 源码：<https://github.com/OpenDevicePartnership/patina>，Discussions 里有定期 community call。
- 贡献流程：文档书 `code_first/code_first_process.md`，大改动先写 RFC（`rfc/template.md`）。

---

## 附录 A：Patina 代码里的 Rust 速查

只列读 Patina 代码反复碰到的，按出现频率排。

| 写法 | 意思 | C 里最接近的东西 |
| --- | --- | --- |
| `#![no_std]` | 不用标准库，只用 `core` 和 `alloc` | 固件环境本来就没有 libc |
| `static X: T = ...;` + `const fn` | 编译期构造的全局对象 | 带初始化器的全局变量 |
| `Result<T, E>` / `?` | 返回值或错误；`?` 遇错立即返回 | `EFI_STATUS` + `if (EFI_ERROR(Status)) return Status;` |
| `Option<T>` | 可能没有值 | 可能为 NULL 的指针，但编译器强制你检查 |
| `fn f(self)` / `(&self)` / `(&mut self)` | 消耗自己 / 只读借用 / 可写借用 | this 指针的三种所有权约定 |
| `trait T { fn f(&self); }` + `impl T for S` | 接口与实现 | 协议结构体里的函数指针表 |
| `dyn T` | trait 对象，运行时多态 | `struct { vtable*, this* }` |
| `impl<P: PlatformInfo> Core<P>` | 泛型，编译期单态化 | 宏或模板，零开销 |
| `type X = ...;`（trait 内） | 关联类型 | 配置宏 |
| `#[derive(...)]` / `#[component]` | 编译期代码生成 | 没有对应物，比宏强得多 |
| `unsafe { ... }` | 这段代码编译器不能验证内存安全，作者负责 | 普通 C 代码，但被圈出来了 |
| `Box::leak(x)` | 堆对象转 `'static` 引用，永不释放 | `AllocatePool` 不 `FreePool` |
| `Once<T>` / `spin::Mutex` / `TplMutex` | 只写一次 / 自旋锁 / TPL 锁 | 全局指针判空 / `CoreAcquireLock` |
| `#[repr(C)]` | 结构体按 C 布局 | 默认布局 |
| `extern "efiapi" fn` | UEFI 调用约定 | `EFIAPI` |
| `*const T` / `*mut T` | 裸指针，解引用要 `unsafe` | 指针 |
| `'static` / `'a` | 生命周期标注，保证引用不悬垂 | 没有对应物，靠纪律 |
| `log::info!("{x}")` | 格式化日志 | `DEBUG((DEBUG_INFO, "%x", x))` |
| `env!("CARGO_PKG_VERSION")` | 编译期读 Cargo.toml | `-D` 宏定义 |

读不懂某个语法时，优先查 Patina 文档书 `dev/principles/` 下的 `unsafe.md`、`ffi.md`、`error-handling.md`，那是 Patina 自己的编码约定，比通用 Rust 教程更贴合。

## 附录 B：常见报错对照表

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `'GenSec' is not recognized` | `CLANGPDB_DLL` 未定义，PATH 前导分号，Windows 11 cmd.exe 找不到任何命令 | 设 `CLANGPDB_DLL`（`build_q35.ps1` 已做） |
| `-Werror,-Wunused-but-set-global` | clang 23 新警告 | 用 LLVM 21（`setup.ps1` 已做） |
| `Filename too long`（clone MU_BASECORE） | Windows 260 字符路径限制 | `core.longpaths=true`，仓库放短路径（`setup.ps1` 已做） |
| `Components not dispatched: ... Service<dyn X> not available` | 没人生产该服务 | 检查生产者是否注册、是否自己也卡在某个依赖上 |
| `Components not dispatched: ... Config<X> ...` | 配置没注册，或者永远没锁定 | `ComponentInfo::configs` 里 `add.config`；检查是否有 `ConfigMut<X>` 的组件没跑完 |
| `Driver X found but not dispatched` | C 驱动 depex 不满足 | 和 Tiano 一样查协议 |
| `Missing architectural protocol: ..., "Timer"` | 提供该架构协议的驱动没进 FV 或没分发 | 核对 FDF 和 depex |
| `No parser registered for HOB: GuidHob { ... }` | 警告，有 GUID HOB 没组件消费 | 需要就写 `FromHob`，不需要忽略 |
| `DXE Core failed to start: ...` 后直接进 BDS | `start_dispatcher` 某步返回 `Err` | 往上找第一条 `ERROR` |
| QEMU 立刻退出且退出码非零 | panic → `qemu_fail` | 往上找 `panicked at` 和 `StackTrace` |
| `cargo make` 报找不到 target `x86_64-unknown-uefi` | rustup 没装 UEFI target | 在 `patina-dxe-core-qemu` 目录运行 `rustup show` |
| `#[component]` 编译错误提示参数冲突 | `Config<T>` 和 `ConfigMut<T>` 同时出现，或 `&mut Storage` 与 `Config` 同时出现 | 改用 `Commands` |

## 附录 C：术语表

| 中文 | English | 说明 |
| --- | --- | --- |
| 组件 | Component | Patina 里和核心静态链接、靠参数声明依赖的 Rust 模块 |
| 服务 | Service | Rust 组件之间的接口，`Service<dyn Trait>` |
| 配置 | Config / ConfigMut | 平台注入的只读/可写数据，有锁定语义 |
| 存储 | Storage | 组件分发器持有的"所有配置、服务、HOB"的容器 |
| 命令队列 | Commands | 延迟到组件返回后再修改 Storage 的队列 |
| 依赖注入 | Dependency injection | 框架按参数类型把依赖传给组件 |
| 分发器 | Dispatcher | 组件分发器（Rust）和 PI 分发器（C 驱动）两个 |
| 全局一致性域 | GCD, Global Coherency Domain | PI 规范的内存/IO 空间管理器 |
| 交接块 | HOB, Hand-Off Block | PEI 传给 DXE 的数据 |
| 固件卷 | FV, Firmware Volume | 存驱动的容器 |
| 段解压器 | Section Extractor | 解压 FV 里压缩段的实现 |
| 架构协议 | Architectural Protocol | PI 规范要求 DXE 必备的 13 个协议 |
| 任务优先级 | TPL, Task Priority Level | UEFI 的中断屏蔽级别 |
| 片上测试 | On-system test | 在固件里跑的 `#[patina_test]` |
| 过程宏 | Procedural macro | 编译期代码生成，如 `#[component]` |
| trait 对象 | Trait object | `dyn Trait`，运行时多态 |
| 关联类型 | Associated type | trait 里由实现者指定的类型 |
| 单态化 | Monomorphization | 泛型按具体类型展开 |
