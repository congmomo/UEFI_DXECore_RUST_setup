# Patina Learning Guide: the Rust DXE Core for C Firmware Engineers

> Audience: firmware engineers who have written EDK II code in C. No Rust experience is assumed; every Rust
> concept is explained where it first matters.
> Baseline: patina 23.3.2, patina-dxe-core-qemu 3.2.6, patina-qemu main as of 2026-10, Windows 11 host.
> Each chapter ends with "Checkpoints": a few self-test questions plus one piece of evidence to find in a QEMU log.
> Log references point into `logs/qemu_q35_local_core_v3.2.6.log` in this repository; line numbers refer to that file.

[中文版](learning-guide.zh.md)

## Contents

1. [The big picture](#1-the-big-picture)
2. [Boot it and learn to read the log](#2-boot-it-and-learn-to-read-the-log)
3. [DXE Core entry and memory initialization](#3-dxe-core-entry-and-memory-initialization)
4. [The component model and dependency injection](#4-the-component-model-and-dependency-injection)
5. [Your first component](#5-your-first-component)
6. [Interoperating with the C world](#6-interoperating-with-the-c-world)
7. [Debugging](#7-debugging)
8. [From QEMU to your own platform](#8-from-qemu-to-your-own-platform)
9. [Evolving with upstream](#9-evolving-with-upstream)
- [Appendix A: Rust cheat sheet for Patina code](#appendix-a-rust-cheat-sheet-for-patina-code)
- [Appendix B: Error lookup table](#appendix-b-error-lookup-table)
- [Appendix C: Glossary](#appendix-c-glossary)

---

## 1. The big picture

### What this chapter answers

You already write DXE drivers in C. This chapter answers three questions: which part of the boot flow Patina
replaces, which parts it does not, and what actually happens when you run `build_q35.ps1 -LocalCore -Run`.

### 1.1 Where Patina sits in the UEFI boot flow

```
 SEC ──> PEI ──────────────> DXE ─────────────────────> BDS ──> OS
 (C)     (C, 32-bit)         │                          (C)
                             │  DXE Core          ← Patina (Rust, 64-bit)
                             │  CpuDxe's job      ← built-in Patina component
                             │  RuntimeDxe's job  ← built into Patina
                             │  all other drivers ← still C, dispatched from FVs as usual
```

Three boundaries to remember:

- **PEI stays C.** Patina's entry point takes one argument: the HOB list pointer. PEI must produce the memory
  resource descriptor HOBs, FV HOBs and platform configuration HOBs. This defines the PEI-side work in chapter 8.
- **The DXE Core is Rust end to end.** Not "a C core with Rust wrappers". System Table, Boot Services, GCD,
  events/TPL, protocol database, image loading and the dispatcher are all Rust in the `patina_dxe_core` crate.
- **C drivers keep working.** Patina's PI dispatcher reads FFS files from FVs, loads PE32 images and dispatches
  by depex, exactly like the Tiano DxeCore. Your existing C drivers do not change.

### 1.2 What the three repositories own

| Repo | Produces | Where you meet it |
| --- | --- | --- |
| `patina` (published on crates.io as `patina_dxe_core`, `patina` and friends) | Libraries: the DXE Core implementation plus the SDK for writing components | Chapters 3, 4, 6 (reading source) |
| `patina-dxe-core-qemu` | A binary crate that instantiates the library into `qemu_q35_dxe_core.efi` | Chapter 5 (you modify it), chapter 8 (you copy it) |
| `patina-qemu` | A complete firmware platform (OvmfPkg fork) that packs the `.efi` into an FD and launches QEMU | Chapter 2 (its log), chapter 6 (its FDF) |

Source on this machine: the `patina` crates live under
`%USERPROFILE%\.cargo\registry\src\<index>\patina_dxe_core-23.3.2\` and siblings. When this guide says
`patina_dxe_core/src/lib.rs`, that is the file to open.

### 1.3 Data flow of one build

```
patina-dxe-core-qemu/bin/q35_dxe_core.rs     ┐
patina-dxe-core-qemu/src/q35/**              │ cargo make q35
patina_dxe_core / patina / patina_* (registry)┘      │
                                                     ▼
          target/x86_64-unknown-uefi/debug/qemu_q35_dxe_core.efi   (PE32+, subsystem = EFI boot service driver)
                                                     │
patina-qemu/Platforms/QemuQ35Pkg/QemuQ35Pkg.fdf      │ stuart_build ... BLD_*_DXE_CORE_PATH=...
   [FV.RUST_DXE_CORE]  FILE DXE_CORE = 23C9322F-... {SECTION PE32 = $(DXE_CORE_PATH)/debug/qemu_q35_dxe_core.efi}
                                                     ▼
          Build/QemuQ35Pkg/DEBUG_CLANGPDB/FV/QEMUQ35_CODE.fd  +  QEMUQ35_VARS.fd
                                                     │ qemu-system-x86_64 -drive if=pflash,...
                                                     ▼
          PEI (C) finds the DXE_CORE file in FV.RUST_DXE_CORE ──> jumps to efi_main(hob_list)
```

Two design choices worth noticing:

- The Rust side is a **separate workspace** built with the standard cargo toolchain; it is not wired into the
  EDK II build system. EDK II only ever sees a finished `.efi`. That is why `build_q35.ps1` runs `cargo make`
  first and `stuart_build` second.
- The Rust DXE Core and every component it hosts are **one monolithic binary**. Patina components are not
  separate `.efi` files; they are statically linked with the core. Chapter 4 explains what that buys.

### Checkpoints

- What is the single argument PEI hands to Patina? (the HOB list pointer)
- Does CpuDxe still belong in the FDF? (no, the `CpuArchProtocolInstaller` component took over)
- **Log evidence**: find `DXE Core Platform Binary v3.2.6` and `DXE Core Crate v23.3.2` at lines 4231 and 4232 of
  `logs/qemu_q35_local_core_v3.2.6.log`. The first comes from `_start` in `bin/q35_dxe_core.rs`, the second from
  `init_memory` in `patina_dxe_core/src/lib.rs`. Between them is the C-to-Rust handoff.

---

## 2. Boot it and learn to read the log

### What this chapter answers

Every later chapter asks you to find evidence in the log, so first we slice a full boot log into phases and map
each phase to source.

### 2.1 Produce a log

```powershell
.\build_q35.ps1 -RunOnly -Headless > my_boot.log 2>&1
```

In headless mode the firmware log reaches the console through QEMU's `-debugcon stdio` (I/O port 0x402, see
`Uart16550::new_io(0x402)` in `q35_dxe_core.rs`) and the UEFI Shell runs `reset -s` to power off. The first three
hundred lines are stuart's own output; firmware output starts right after the `qemu-system-x86_64` command line.

### 2.2 Phases of the log (`logs/qemu_q35_local_core_v3.2.6.log`)

| Line | Landmark | Printed by | Source |
| --- | --- | --- | --- |
| ~330 | `Cmd to run is: ...qemu-system-x86_64 -debugcon stdio ...` | stuart | `Platforms/QemuQ35Pkg/Plugins/QemuRunner/QemuRunner.py` |
| 330 – 4230 | SEC/PEI output: `QemuFwCfg`, `Q35TsegMbytesInitialization`, `Stack Guard set at`, MM Supervisor loading, `Patch page table done!` | **C code** | `patina-qemu/Platforms/QemuQ35Pkg/PlatformPei`, `Features/MM_SUPV` |
| 4231 | `DXE Core Platform Binary v3.2.6` | Rust, platform binary | `q35_dxe_core.rs::_start` |
| 4232 | `DXE Core Crate v23.3.2` | Rust, library | first line of `lib.rs::init_memory` |
| 4232 – 4790 | `HOB list discovered is:` followed by a long HOB dump; `GCD - After memory init:` | library | `init_memory` |
| 4851 – 4905 | `Registering platform components` / `Registering default components` / `Initializing System Table` / `Parsing HOB list for Guided HOBs.` / `Installing Firmware Volumes from HOB list.`, each followed by `Finished.` | library | `lib.rs::start_dispatcher` |
| 4906 | `Dispatching Drivers` | library | `start_dispatcher` → `core_dispatcher` |
| 4907 – 4932 | `Dispatching patina_dxe_core::cpu::cpu_arch_protocol::CpuArchProtocolInstaller` … `Dispatching patina_test::component::TestRunner` | component dispatcher | `component_dispatcher.rs::dispatch` |
| 4933 – 6558 | 125 × `Loading driver at` / `Loaded image at`, interleaved with each C driver's own output | PI dispatcher + C drivers | `pi_dispatcher.rs::dispatch` |
| 6559 | `Finished Dispatching Drivers` | library | `start_dispatcher` |
| 6560 – 6565 | the `Components not dispatched:` table | library | `component_dispatcher.rs::display_not_dispatched` |
| 6567 | `[Bds] Entry...` | **C code** (the BDS driver) | reached through `lib.rs::call_bds` |
| 6948 | `Patina on-system unit-test result totals: 27 passes, 0 fails` | `patina_test` | runs on the ReadyToBoot event |
| 8290 | `Loaded image ... Shell.efi` | PI image loader | `pi_dispatcher/image.rs` |
| 8308 | `DXE ResetSystem2: ResetType Shutdown` | the C ResetSystem runtime driver | `reset -s` from `startup.nsh` |

This table is the map for the whole guide. You should be able to reproduce every row with `grep -n`.

### 2.3 Three kinds of "not dispatched"

The table at line 6560 is the most informative few lines of the whole log:

```
Components not dispatched:
name                                                    error message
patina_performance::component::performance::Performance patina::component::service::Service<dyn ...PerformanceManager> not available.
Driver PrintScreenLogger (EA205B85-...) found but not dispatched.
Driver DisplayEngine (C09E4CE4-...) found but not dispatched.
```

- The first row is a **Rust component** that was not dispatched: the `Service<dyn PerformanceManager>` it asks
  for was never produced. Chapter 4 explains the mechanism. Performance tracing is off by default
  (`BLD_*_PERF_TRACE_ENABLE=FALSE`), so this is expected.
- The other two rows are **C drivers** with unsatisfied depex, exactly as in Tiano. Headless runs have no display
  device, so the protocol `DisplayEngine` depends on never appears. Run once with a window (`-RunOnly` without
  `-Headless`) and both rows disappear. The total number of on-system tests (27, 32, ...) varies with
  configuration and timing; do not use it as a regression metric, `0 fails` is what matters.

If an architectural protocol were missing you would also see `Missing architectural protocol: ..., "Timer"` lines
here, from `lib.rs::core_display_missing_arch_protocols`. None appear in this log: all 13 are present.

### 2.4 Log level and filtering

The `static LOGGER` in `q35_dxe_core.rs` sets the global level to `Info` and silences a list of noisy targets
(`goblin`, `gcd_measure`, `allocations`, `efi_memory_map`, ...). To watch every GCD allocation, delete the
`allocations` entry and rebuild. In release builds `log::debug!`/`log::trace!` are compiled out entirely by the
`release_max_level_info` feature on the `log` dependency in `Cargo.toml`.

### Checkpoints

- Before which line is it C, and after which line Rust? (4231)
- After `Finished Dispatching Drivers` there is still plenty of C driver output; who dispatched those?
  (`ConnectController` in BDS, through the UEFI driver model, not the DXE dispatcher)
- **Log evidence**: run once with a window and confirm `DisplayEngine` disappears from the not-dispatched table.

---

## 3. DXE Core entry and memory initialization

### What this chapter answers

Follow the code from `efi_main` to the moment the dispatcher starts. The focus is memory: how the GCD is built
from HOBs, when the heap becomes usable, and why the HOB list is relocated.

### 3.1 The platform binary's entry (`bin/q35_dxe_core.rs`)

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

> **Rust**: `static CORE` is a global object constructed at compile time; `Core::new` is a `const fn`, so no
> runtime initialization and no heap are needed. `extern "efiapi"` is the `EFIAPI` calling convention. `-> !`
> means the function never returns, like `DxeMain`. `unsafe` on the function signature tells callers "I cannot
> verify this pointer".

Compare with C: `DxeMain(VOID *HobStart)`. Same argument, same responsibility.

### 3.2 `Core::entry_point` (`patina_dxe_core/src/lib.rs`)

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

Three steps: build memory, run the dispatcher, jump to BDS. `set_instance` stores the address of `&'static self`
in a `Once` so that `extern "efiapi"` callbacks that have no `self` (the function pointers in the Boot Services
table) can find the core object.

### 3.3 `init_memory`: from "no allocation" to "allocation"

In source order (`lib.rs` from line 411):

1. `cpu::initialize_cpu_subsystem(P::CpuInfo::exception_handlers())`: IDT and exception handlers. The platform
   can inject its own handlers through the `CpuInfo` trait.
2. `gcd::init_gcd(physical_hob_list)`: using **only the memory resource descriptor HOBs**, mark one known-free
   region of system memory in the GCD. The comment says it plainly: after this point the Rust heap is allowed.
   The GCD itself (`gcd/spin_locked_gcd.rs`) runs on a static array before initialization, with no heap.
3. `hob_list.discover_hobs(physical_hob_list)`: parse the PI-format HOB list into a Rust `HobList`
   (`patina::pi::hob`) and print `HOB list discovered is:`.
4. `PROTOCOL_DB.init_protocol_db()`: create the well-known handles.
5. `allocator::init_memory_support(&hob_list)`: process memory allocation HOBs and memory bins (regions reserved
   per memory type, see the Patina book `dxe_core/memory_bins.md`); the allocator is now fully functional.
6. **Relocate two copies of the HOBs**: the raw PI bytes are `Box::leak`ed for the C drivers' `HobLib` (they still
   find HOBs through the `gEfiHobListGuid` configuration table), and the Rust `HobList` is stored in
   `self.hob_list` after `relocate_hobs()`. Why relocate: the list PEI handed over may not be in mapped memory,
   and the initial free region may be too small.
7. Debugger initialization and the performance timer frequency (`P::CpuInfo::perf_timer_frequency()`; Q35
   calibrates the TSC against the ACPI PM Timer).
8. Four core services go into component storage: `DxeInterruptManager`, `CoreMemoryManager`,
   `CoreDxeDispatch`, `PerfTimer`. Chapter 4 explains what a service is.
9. Print `GCD - After memory init:` (log line 4790).

> **Rust**: `Box::leak` turns a heap allocation into a `'static` reference, deliberately "leaking" it; the C
> equivalent is `AllocatePool` with no `FreePool`. Plenty of DXE state legitimately lives until
> ExitBootServices, so this is a reasonable idiom. `Once` is a write-once cell that replaces the
> `if (gPtr == NULL)` pattern around C globals.

### 3.4 Memory protection

After `init_memory`, the GCD and the paging subsystem (`gcd/spin_locked_gcd/paging.rs`, built on the
`patina_paging` crate) maintain the page tables together. The many `Applying image memory protections on 0x...
with attributes 0x...` lines are NX/RO being applied per section at image load. Two related features in
`patina_dxe_core/Cargo.toml`:

- `compatibility_mode_allowed`: let images that do not satisfy the protection requirements (typically old OS
  loaders) fall back to a compatibility mode. `patina-dxe-core-qemu` enables it by default.
- `v1_resource_descriptor_support`: accept the old resource descriptor HOB format. On for the OVMF target, off
  for Q35, whose PEI already produces v2 HOBs.

### Checkpoints

- When does the heap become usable? (after `init_gcd`)
- Why are there two copies of the HOBs? (C drivers need the raw PI layout; Rust components need the parsed `HobList`)
- **Log evidence**: take the `physical_start` of the first `ResourceDescriptor` after `HOB list discovered is:` and
  find the same address in the `GCD - After memory init:` table.

---

## 4. The component model and dependency injection

### What this chapter answers

What a Patina component looks like, how it differs from a C driver, and who decides dispatch order. Afterwards the
`ComponentInfo` registration block in `bin/q35_dxe_core.rs` should read naturally.

### 4.1 The fundamental difference from a C driver

| | C DXE driver | Patina component |
| --- | --- | --- |
| Packaging | its own `.efi` in an FV | statically linked into the core binary |
| Declaring dependencies | `[Depex]` in the INF, by protocol GUID | the **parameter types** of the entry function |
| Entry | `EFI_STATUS EFIAPI Entry(ImageHandle, SystemTable)` | `fn entry_point(self, params...) -> Result<()>` |
| Getting dependencies | `gBS->LocateProtocol`, by hand | injected by the framework, by type |
| Publishing an interface | `InstallProtocolInterface` + raw pointer | `Service<dyn Trait>`, type-safe |
| Failure | returns a status, may be retried | returns `Err`, logged, never retried |

The idea comes from the ECS pattern of the Bevy game engine (the docs at the top of `patina/src/component.rs`
say so): **a component declares what it needs; the framework calls it once that is available.**

### 4.2 The smallest component

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

(Verbatim from `patina_samples/src/component/hello_world.rs`.)

Rules:

- The `#[component]` attribute goes on an `impl` block that **must** contain a method named `entry_point`. The
  macro generates the `IntoComponent` implementation and checks parameter conflicts at compile time.
- The first parameter is `self` (consumes the object; the common case) or `&self`/`&mut self`.
- Every other parameter (at most 5; use a tuple for more) must implement the `Param` trait.

> **Rust**: `#[component]` is a procedural macro, a code generator that runs at compile time, defined in the
> `patina_macro` crate. Taking `self` by value means the component object is consumed on dispatch, which is why a
> component naturally runs exactly once.

### 4.3 Parameter types are dependencies

The table from `patina/src/component.rs`, ordered by how often you will use each:

| Parameter | Meaning | Satisfied when |
| --- | --- | --- |
| `Config<T>` | read-only configuration | the config of type T is **locked** |
| `ConfigMut<T>` | writable configuration | the config of type T is **unlocked** |
| `Service<dyn Trait>` | an interface someone else provides | someone called `add_service` |
| `Hob<T>` | a parsed GUID HOB (possibly several; `iter()`) | a HOB with that GUID exists |
| `Commands` | deferred queue: `add_config`, `add_service` | always |
| `&mut Storage` / `&Storage` | direct storage access (discouraged; conflicts easily) | always |
| `StandardBootServices` | the Rust Boot Services wrapper | always |
| `Option<P>` | wrap anything: run even when unavailable, receive `None` | always |

**Config locking** (`params.rs` docs): configs registered by the platform in `ComponentInfo::configs` via
`add.config(x)` start out locked. If any component declares `ConfigMut<T>`, the framework unlocks that config;
once every writer has run (explicit `lock()` or automatic when nothing else can run), components asking for
`Config<T>` become dispatchable. Q35's `MmConfigurationProvider` is the canonical example: it takes
`Hob<MmCommRegionHob>` and `ConfigMut<MmCommunicationConfiguration>`, fills in the ACPI base it probes at runtime,
and only then can `SwMmiManager` and `MmCommunicator` start with `Config<MmCommunicationConfiguration>`.

### 4.4 Who decides dispatch order

`patina_dxe_core/src/component_dispatcher.rs::dispatch`:

```rust
self.components.retain_mut(|component| {
    !match component.run(&mut self.storage) {
        Ok(true)  => true,   // dependencies met, executed, remove from queue
        Ok(false) => false,  // dependencies not met, keep in queue
        Err(err)  => { log_debug_assert!(...); true } // executed and failed, remove, never retry
    }
});
```

The outer loop in `lib.rs::core_dispatcher`:

```rust
loop {
    let dispatched = self.component_dispatcher.lock().dispatch();     // Rust components first
    let dispatched = dispatched || self.pi_dispatcher.dispatch()?;     // then C drivers
    if !dispatched { break; }
}
```

`start_dispatcher` calls `core_dispatcher` twice with `lock_configs()` in between, so the full semantics are:

1. Dispatch repeatedly until a round finds nothing new, Rust or C.
2. Lock every config that is still unlocked.
3. Dispatch repeatedly again (now the `Config<T>` consumers can run).
4. Print what was never dispatched.

There is **no explicit ordering** between components. The order of `add.component` calls only affects the attempt
order within a round; the real dependencies are the parameter types. That is why the chapter 5 exercise can
register the consumer first.

### 4.5 Service: the Rust-side protocol

```rust
trait MyService { fn do_it(&self); }

#[derive(IntoService)]
#[service(dyn MyService)]
struct MyServiceImpl;
impl MyService for MyServiceImpl { fn do_it(&self) {} }

// producer
fn producer(mut commands: Commands) -> Result<()> { commands.add_service(MyServiceImpl); Ok(()) }
// consumer: not dispatched until someone produced the service
fn consumer(s: Service<dyn MyService>) -> Result<()> { s.do_it(); Ok(()) }
```

Key points (`service.rs` docs): a registered service is `'static` and read-only, so trait methods take `&self`;
mutable state needs interior mutability (`RefCell`, `spin::Mutex`, atomics). A service may hold another
`Service<dyn X>` captured at construction time, and the framework orders production accordingly.

> **Rust**: `dyn Trait` is a trait object, roughly "a function-pointer table plus a this pointer" as in a C
> protocol struct, except the compiler builds the table. `#[derive(IntoService)]` registers `GreetingImpl` in
> storage under the identity `dyn Greeting`.

### 4.6 Hob: declarative GUID HOB parsing

```rust
#[derive(FromHob, Default, Clone, Copy, zerocopy::FromBytes)]
#[hob = "d4ffc718-fb82-4274-9afc-aa8b1eef5293"]
#[repr(C)]
pub struct MmCommRegionHob { buffer_type: u64, address: u64, pages: u64 }
```

`#[repr(C)]` guarantees the C layout; `zerocopy::FromBytes` allows a copy-free cast from bytes; `#[hob = "..."]`
names the GUID. For complex layouts implement `FromHob::parse` by hand. `insert_hobs` in `start_dispatcher`
parses every GUID HOB into storage up front; the `No parser registered for HOB: GuidHob { ... }` warnings mean
"no component ever declared this GUID".

### Checkpoints

- A component asks for `Config<T>` but the platform never registered T. What happens? (it is never dispatched and
  shows up in the not-dispatched table)
- Does `add.component` order define execution order? (no)
- **Log evidence**: line 4916 `MmConfigurationProvider` precedes line 4921 `SwMmiManager`. Swap their registration
  order in `bin/q35_dxe_core.rs`, rebuild, and the log order stays the same.

---

## 5. Your first component

### What this chapter answers

Turn chapter 4 into a component you can build, boot and see in the log. The complete code is in
`examples/hello_component/`; this chapter explains why each piece looks the way it does.

### 5.1 Goal

Two components, one service, one config:

- `HelloGreeter`: has state (a name), reads `Config<GreetingConfig>`, produces `Service<dyn Greeting>`.
- `GreetingConsumer`: consumes `Service<dyn Greeting>`.
- The consumer is registered **first on purpose**, to prove the framework orders by dependency.

### 5.2 Code walkthrough (`examples/hello_component/src/lib.rs`)

**Crate skeleton**

```rust
#![no_std]
extern crate alloc;
use alloc::{format, string::String};
```

> **Rust**: there is no operating system under firmware, so `#![no_std]` drops the standard library, leaving
> `core` (no heap) and `alloc` (heap; Patina's allocator is live after `init_gcd`). `String`, `Vec` and `Box`
> come from `alloc`.

**Config type**

```rust
#[derive(Debug, Default, Clone, Copy)]
pub struct GreetingConfig { pub exclamation_marks: usize }
```

`Config<T>` requires `T: Default`, hence `derive(Default)`.

**Service trait and implementation**

```rust
pub trait Greeting { fn greeting(&self) -> String; }

#[derive(IntoService)]
#[service(dyn Greeting)]
struct GreetingImpl { text: String }
impl Greeting for GreetingImpl { fn greeting(&self) -> String { self.text.clone() } }
```

`GreetingImpl` is private; the outside world only knows `dyn Greeting`. That is interface/implementation
separation.

**Producer**

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

`Commands` rather than `&mut Storage`: the `params.rs` docs state that `&mut Storage` conflicts with
`Config<T>` in the same signature (you could mutate storage while reading a config from it). `Commands` defers
the structural change until the entry point has returned.

**Consumer**

```rust
#[component]
impl GreetingConsumer {
    fn entry_point(self, greeting: Service<dyn Greeting>) -> Result<()> {
        log::info!("[hello_component] consumer got: {}", greeting.greeting());
        Ok(())
    }
}
```

### 5.3 Wiring it into the platform

`examples/hello_component/apply.ps1` makes two edits (doing them by hand is fine too):

1. `patina-dxe-core-qemu/Cargo.toml`, under `[dependencies]`: `hello_component = { path = "../examples/hello_component" }`.
2. `bin/q35_dxe_core.rs`:
   - in `fn configs`: `add.config(hello_component::GreetingConfig { exclamation_marks: 3 });`
   - in `fn components`, right after `AdvancedLoggerComponent`: the two `add.component(...)` lines, consumer first.

Why after AdvancedLogger: components only log when dispatched and `LOGGER` is already installed in `_start`, so
any position works; placing them later just keeps the log tidy.

### 5.4 Build, run, verify

```powershell
.\examples\hello_component\apply.ps1
.\build_q35.ps1 -LocalCore -Headless -Run > hello.log 2>&1
Select-String -Path hello.log -Pattern "hello_component"
```

Four lines, in a fixed order (the recorded run is `logs/qemu_q35_hello_component.log`, lines 4919–4939):

```
Dispatching hello_component::HelloGreeter
[hello_component] Hello, Patina learner!!!  (config says 3 exclamation marks)
Dispatching hello_component::GreetingConsumer
[hello_component] consumer got: Hello, Patina learner!!!
```

The consumer was registered first, but its first `run` returns `Ok(false)` (no service yet) and it stays in the
queue; the producer runs, `Commands` writes the service into storage, and the consumer runs in a later round.
In the recorded log a dozen other components dispatch between the two.

To restore the upstream files afterwards: `.\examples\hello_component\apply.ps1 -Revert`.

### 5.5 Exercises

1. Change the consumer's parameter to `Option<Service<dyn Greeting>>` and comment out the `HelloGreeter`
   registration. The consumer still runs and takes the `None` branch.
2. Add a component with `ConfigMut<GreetingConfig>` that sets `exclamation_marks` to 10 and watch what
   `HelloGreeter` reads. Understand the locking moment: it dispatches only after your writer ran and the config
   was locked.
3. Make `entry_point` return `Err(patina::error::EfiError::DeviceError)`; find `Dispatched: ... Status = [Failed]`
   in the log and confirm it is not retried.
4. On-system tests (already written, `mod tests` in `src/lib.rs`): two `#[patina_test]` functions, one asserting
   that `Service<dyn Greeting>` exists and carries the registered name, one also injecting
   `Config<GreetingConfig>` and asserting the exclamation-mark count matches the config. Key points: test
   functions receive dependencies through parameter types exactly like components;
   `#[on(event = BinaryGuid(efi::EVENT_GROUP_READY_TO_BOOT))]` runs them after every component and driver has
   dispatched, so the service is guaranteed to exist; assertions use `u_assert!`/`u_assert_eq!`, which return an
   error string instead of panicking. Look for `hello_component::tests::greeting_service_exists ... ok` and
   `greeting_matches_config ... ok` under `Patina on-system unit-test results`. Exercise: change
   `exclamation_marks` to 5 in `apply.ps1` and rerun; both tests still pass. Then hard-code 3 in the test and see
   what a failure looks like, and how `exit_on_patina_test_failure` makes QEMU exit non-zero.

### Checkpoints

- Why `Commands` instead of `&mut Storage`?
- Why does registering the consumer first not run it first?
- **Log evidence**: your own `hello.log` shows the four lines in the order above.

---

## 6. Interoperating with the C world

### What this chapter answers

95 % of your platform's drivers are still C. This chapter covers how Patina loads them, how a Rust component calls
a C protocol, and how a C driver can use something Rust publishes.

### 6.1 How Patina runs C drivers

`patina_dxe_core/src/pi_dispatcher.rs`:

- `install_firmware_volumes_from_hoblist`: walk the FV HOBs and install `FirmwareVolumeBlock` and
  `FirmwareVolume2` on each (the three pairs of `InstallProtocolInterface` after log line 4898).
- `dispatch`: scan FFS files in each FV, read the depex section, evaluate it against the protocol database, load
  the ones that qualify as PE32 (`pi_dispatcher/image.rs`, parsing PE/COFF with the `goblin` crate and doing
  relocations itself) and call their entry points. Nested FVs and compressed sections
  (`section_decompress.rs`, via `P::Extractor`, i.e. `CompositeSectionExtractor` for Brotli/LZMA/Tiano) are handled.
- `schedule`/`trust`: implement the DXE Services `Schedule` and `Trust` used by the `SecurityArch` protocol.

This is a peer implementation of Tiano's `DxeCore/Dispatcher`; even the `Loading driver at 0x... EntryPoint=0x...
XXX.efi` line format is kept so WinDbg symbol scripts keep working.

### 6.2 Boot Services, in Rust

The `gBS` a C driver receives points at the table built in `patina_dxe_core/src/systemtables.rs`; every function
pointer in it is an `extern "efiapi" fn` living in `protocols.rs` (Install/Locate/Open/Close...), `events.rs`
(CreateEvent/SignalEvent/TPL), `memory_manager.rs` (AllocatePages/Pool), `driver_services.rs`
(Connect/Disconnect/LoadImage/StartImage) and `misc_boot_services.rs`.

These functions have no `self`, so they work through the `__SELF` pointer from chapter 3 and the globals
`PROTOCOL_DB`, `GCD`, `EVENT_DB`. Global state is guarded by `TplMutex` (`tpl_mutex.rs`): lock = `RaiseTPL`,
unlock = `RestoreTPL`, the same semantics as `CoreAcquireLock` in the C core.

### 6.3 Calling C protocols from a Rust component

Declare `StandardBootServices` as a parameter (`patina/src/uefi/boot_services.rs`). It wraps `locate_protocol`,
`install_protocol_interface`, `create_event`, `handle_protocol` and friends, returning `Result` instead of
`EFI_STATUS`. Protocol structs are defined in `patina::pi::protocol` and `patina::standard::efi::protocols` (from
the `r-efi` crate). Calling the C function pointer is still `unsafe`; the wrapper only takes care of NULL checks
and status conversion.

The `protocol_handler` and `boxed` submodules of `patina::uefi::boot_services` are the next step: the former wraps
protocol notifications safely, the latter puts `AllocatePool` memory behind a `Box` that frees itself.

### 6.4 Letting C drivers use what Rust publishes

Two routes:

1. **Install a protocol directly.** From a component, call `StandardBootServices::install_protocol_interface`
   with a `#[repr(C)]` struct of `extern "efiapi"` functions. You are writing a C ABI in Rust. Patina's own
   `CpuArchProtocolInstaller` and `DecompressProtocolInstaller` do exactly this (`cpu/cpu_arch_protocol.rs`,
   `decompress.rs`).
2. **Publish a Service as a protocol too.** The `IntoService` derive can register a service as an EDK II
   protocol (see "Protocol Backwards Compatability" in the `service.rs` docs), but the docs insist this is for
   compatibility only and should be avoided when possible.

In the other direction (Rust consuming a C protocol) prefer `StandardBootServices`; do not wrap a C protocol in a
Service unless you plan to replace that C driver with Rust later.

### 6.5 The architectural protocol list

`ARCH_PROTOCOLS` in `lib.rs` lists 13 (Security, Cpu, Metronome, Timer, Bds, Watchdog, Runtime, Variable,
Variable Write, Capsule, Monotonic Counter, Reset, Real Time Clock). After dispatch the core `locate_protocol`s
each one and warns `Missing architectural protocol` for any absentee. On Q35, Cpu comes from a Rust component and
the rest from C drivers. When porting, this is the first checklist to verify.

### Checkpoints

- Which file implements `gBS->LocateProtocol` in Rust? (`protocols.rs`)
- Should two Rust components talk through a Service or a protocol? (Service)
- **Log evidence**: find `installed EFI_CPU_ARCH_PROTOCOL_GUID` (line 4909) and confirm it precedes every
  `Loading driver at`, so the Cpu architectural protocol exists before any C driver dispatches.

---

## 7. Debugging

### What this chapter answers

What a panic looks like, how to attach a debugger, how to turn logging up.

### 7.1 panic and assert

The `#[panic_handler]` in `bin/q35_dxe_core.rs` prints the panic message, dumps the stack with
`StackTrace::dump()`, calls `patina_debugger::breakpoint()`, and finally `qemu_fail()` makes QEMU exit with a
non-zero code through the `isa-debug-exit` device. In CI a panic therefore equals a failed test.

Rust `assert!`, array bounds violations, integer overflow (debug builds) and `unwrap()` on `None`/`Err` all end
up here. This is the essential difference from a C `ASSERT` that continues, or silent memory corruption:
**Patina stops rather than runs while broken.**

Core code also uses `log_debug_assert!` (from the `patina` crate): panic in debug builds, log only in release.
`component_dispatcher.rs` handles a component's `Err` with it.

### 7.2 The software debugger (patina_debugger)

`patina_debugger` hooks the exception handlers and speaks the GDB remote protocol over a serial port. Q35 uses
COM1 (0x3F8):

```rust
static DEBUGGER: PatinaDebugger<Uart16550> =
    PatinaDebugger::new(unsafe { Uart16550::new_io(0x3F8) })
        .with_force_enable(_ENABLE_DEBUGGER)
        .with_log_policy(DebuggerLoggingPolicy::FullLogging);
```

Two cargo features: `build_debugger` compiles it in (on by default for debug builds), `enable_debugger` makes it
stop at an initial breakpoint. Build:

```powershell
cd patina-dxe-core-qemu
cargo make q35 --features enable_debugger
```

On the QEMU side expose COM1 as TCP: `stuart_build ... SERIAL_PORT=50001 --FlashOnly`. This repository's script does
both steps in one go: `.\build_q35.ps1 -EnableDebugger -Run -SerialPort 50001 -GdbServer 5555` (`-GdbServer` is the
`GDB_SERVER` option from section 7.3; patina-qemu's own `build_and_run_rust_binary.py` defaults to 50001). Then connect GDB with `target remote :50001`, or follow
`patina-qemu/docs/src/debugging/windbg_uefi.md` to use WinDbg through the EXDi plug-in from
microsoft/uefi_debug_tools. The debugger also supports custom monitor commands (`add_monitor_command`) and the
`debugger_reload` feature (swap in a freshly built DXE Core image without restarting QEMU; see the book,
`dev/debugging/core_reload.md`).

### 7.3 Hardware-level debugging

`stuart_build ... GDB_SERVER=5555` enables QEMU's own gdbstub, complementary to the software debugger: the
software debugger sees Rust symbols and module-load events (`notify_module_load`); QEMU's gdbstub still shows
registers when the firmware itself is dead.

Symbols: `cargo make q35` emits a matching `.pdb` (`-C link-arg=/PDBALTPATH:qemu_q35_dxe_core.pdb` in
`Makefile.toml`); C driver PDBs are under `Build/.../PDB/`, and the `Copying Symbols to flat directory` step at
the end of `stuart_build` gathers them.

### 7.4 Turning logging up

- Global level: third argument of `LOGGER` in `q35_dxe_core.rs`.
- Per target: the `TargetFilter` list. The target defaults to the module path, so
  `TargetFilter { target: "hello_component", log_level: Trace, .. }` opens up only your crate.
- Release builds are capped by the `log` crate's `release_max_level_info`; `debug!`/`trace!` do not exist there.

### Checkpoints

- What happens when `unwrap()` fails in a debug build? (panic → stack trace → QEMU exits)
- `build_debugger` versus `enable_debugger`?
- **Log evidence**: in the `patina_test` callback (`with_callback` in `bin/q35_dxe_core.rs`) see `qemu_fail()`
  being called on failure, and understand the `exit_on_patina_test_failure` feature.

---

## 8. From QEMU to your own platform

### What this chapter answers

Copy `patina-dxe-core-qemu` into your own platform crate: what to change, what PEI must provide, what to change on
the EDK II side. The official list is the book's `integrate/patina_dxe_core_requirements_checklist.md`; this
chapter orders it by what you do first.

### 8.1 Rust side: implement four traits

`PlatformInfo` in `patina_dxe_core/src/lib.rs`:

```rust
pub trait PlatformInfo: 'static {
    type MemoryInfo: MemoryInfo;
    type CpuInfo: CpuInfo;
    type ComponentInfo: ComponentInfo;
    type Extractor: SectionExtractor;
    const DEFAULT_PERFORMANCE_CONFIG: PerformanceConfig = PerformanceConfig::new();
}
```

| Trait | What to implement | What Q35 does |
| --- | --- | --- |
| `MemoryInfo` | only `prioritize_32_bit_memory()`, default false | defaults |
| `CpuInfo` | `perf_timer_frequency()`, `exception_handlers()`; `gic_bases()` on AArch64 | calibrates the TSC against the PM Timer |
| `ComponentInfo` | the `configs`, `components`, `services` registration callbacks | registers MM, SMBIOS, ACPI, logger, test components |
| `Extractor` | the section extractor | `CompositeSectionExtractor` (everything) |

> **Rust**: `type X: Bound` inside a trait is an associated type: "the implementor must name a type that satisfies
> Bound". `Core<P: PlatformInfo>` is generic and monomorphized at compile time, so platform configuration costs
> nothing at runtime.

Then:

- Pick a log backend. Q35 uses `AdvancedLogger<Uart16550>` over an I/O port; for an MMIO UART use
  `Uart16550::new_mmio` or `UartPl011` (`patina::peripheral::serial`).
- Pick the debugger's serial port.
- Write the `panic_handler`. Replace QEMU's `qemu_fail` with your platform reset or a halt loop.
- Architecture: the `x64`/`aarch64` features in `Cargo.toml` and the target in `Makefile.toml`. AArch64 also needs
  `CpuInfo::gic_bases()`.

### 8.2 PEI side: HOBs that must be delivered

Patina reads no PCDs and no DSC; everything comes from HOBs:

- **Resource Descriptor HOB v2** (with cache attributes) for all system memory and MMIO. Enable
  `v1_resource_descriptor_support` for platforms that still produce v1.
- **Memory Allocation HOBs** for regions PEI already uses, including the DXE Core's own stack and image.
- **FV HOBs**: at least one FV containing the DXE drivers.
- **Firmware Volume Info HOB**, **CPU HOB** (address/IO width).
- Platform GUID HOBs: Q35 passes the MM communication buffer as `MmCommRegionHob` and a performance config HOB.
  Your platform receives its own through `Hob<T>` parameters.

Validation tool: the `patina-qemu` extdep ships `patina_readiness_tool` (`READINESS.QEMU_ext_dep.json`), a DXE
driver that runs on your existing C firmware and checks whether the HOB list and platform meet Patina's
requirements. Run it before porting.

### 8.3 EDK II side

1. Remove `MdeModulePkg/Core/Dxe/DxeMain.inf`, `CpuDxe` and `RuntimeDxe` from the DSC (Patina provides the latter
   two's functionality).
2. Copy the `[FV.RUST_DXE_CORE]` section from `QemuQ35Pkg.fdf`:
   `FILE DXE_CORE = <GUID> { SECTION PE32 = <your.efi> }`. Keep a command-line override like
   `DXE_CORE_BINARY_OVERRIDE`; CI will want to swap binaries.
3. Make sure PEI's `DxeIpl` finds a file of type `EFI_FV_FILETYPE_DXE_CORE` in an FV. Q35 keeps it in its own FV
   so the DXE Core can be replaced after the build.
4. Replace C drivers with Rust components gradually: pure-software ones first (SMBIOS, ACPI table generation,
   performance records), hardware-facing ones later. After each swap, re-check the architectural protocols with
   the chapter 2 log table.

### 8.4 A porting checklist

- [ ] all four `PlatformInfo` associated types implemented
- [ ] serial log works from the first line of `_start`
- [ ] v2 resource descriptors in the HOBs, or the v1 feature enabled
- [ ] all 13 architectural protocols present after dispatch (no `Missing architectural protocol` warnings)
- [ ] nothing unexpected in the `Components not dispatched` table
- [ ] BDS is reached; `patina_readiness_tool` passes
- [ ] `patina_test` runs clean (chapter 9)

### Checkpoints

- Which of your platform's PCDs must become HOBs?
- What does a wrong `Extractor` look like? (compressed sections fail to extract; drivers are "found but not
  dispatched" or fail to load)
- **Log evidence**: the `No parser registered for HOB` list after line 4860 is exactly the set of GUID HOBs your
  platform would hand to Patina that nobody consumes; decide for each whether it needs a `FromHob`.

---

## 9. Evolving with upstream

### 9.1 Versioning

- `patina-dxe-core-qemu/Cargo.toml` pins by major version (`patina = { version = "23" }`); `Cargo.lock` pins the
  exact one. Upgrading = bump the major + `cargo update`.
- The Rust version is pinned by `rust-toolchain.toml` (currently 1.95.0), and its `[tools]` section pins cargo-make
  and friends. `setup.ps1` reads that file to install them.
- Major versions move fast (11 → 13 → 23). Read the upstream release notes for breaking changes on every bump.

### 9.2 Developing against a local patina checkout

```powershell
git clone https://github.com/OpenDevicePartnership/patina D:\src\patina
cd patina-dxe-core-qemu
cargo make q35 -- --crate-patch D:\src\patina --leave-patch
```

`--crate-patch` writes a `[patch.crates-io]` section into `Cargo.toml` that points every `patina_*` dependency at
the local path; without `--leave-patch` the patch is removed after the build. This is the standard upstream
contribution loop: change `patina`, validate on QEMU, open a PR.

### 9.3 Three layers of tests

| Layer | Command | Runs where | Purpose |
| --- | --- | --- | --- |
| Unit tests | `cargo make test` (patina repo) | host, `std` feature | pure logic: GCD merging, protocol DB, HOB parsing, heavy use of `mockall` |
| On-system tests | `#[patina_test]` + the `TestRunner` component | inside QEMU | audit post-boot state, e.g. `gcd_free_memory_merged_test` |
| Platform CI | `platform-ci.yml` / `nightly-os-boot.yml` in `patina-qemu` | GitHub Actions | boot to Shell, boot Ubuntu and Windows |

An on-system test (`patina_dxe_core/src/core_patina_tests/audit_tests.rs`):

```rust
#[patina_test]
#[on(event = BinaryGuid(efi::EVENT_GROUP_READY_TO_BOOT))]
fn gcd_free_memory_merged_test() -> patina_test::error::Result {
    ...
    u_assert!(cond, "Found adjacent free memory descriptors");
    Ok(())
}
```

`#[on(event = ...)]` picks the event group that triggers the test; without it the test runs when `TestRunner`
dispatches. `TestRunner::default().with_filter(Filter::include("x64"))` filters by name. Results are also emitted as
JSON in the log (`patina_on_system_unit_test_results`) for CI to parse.

### 9.4 Community

- The book: <https://opendevicepartnership.github.io/patina/>; this guide cites its pages by path.
- Source: <https://github.com/OpenDevicePartnership/patina>; Discussions hosts a regular community call.
- Contribution process: `code_first/code_first_process.md` in the book; larger changes start as an RFC
  (`rfc/template.md`).

---

## Appendix A: Rust cheat sheet for Patina code

Only what you keep meeting while reading Patina, roughly by frequency.

| Syntax | Meaning | Closest thing in C |
| --- | --- | --- |
| `#![no_std]` | no standard library, only `core` and `alloc` | firmware never had libc anyway |
| `static X: T = ...;` + `const fn` | global object built at compile time | global with an initializer |
| `Result<T, E>` / `?` | value or error; `?` returns early on error | `EFI_STATUS` + `if (EFI_ERROR(Status)) return Status;` |
| `Option<T>` | maybe a value | a nullable pointer, but the compiler forces the check |
| `fn f(self)` / `(&self)` / `(&mut self)` | consume / shared borrow / exclusive borrow | three ownership conventions for `this` |
| `trait T { fn f(&self); }` + `impl T for S` | interface and implementation | a protocol struct of function pointers |
| `dyn T` | trait object, runtime polymorphism | `struct { vtable*, this* }` |
| `impl<P: PlatformInfo> Core<P>` | generics, monomorphized at compile time | macros or templates, zero cost |
| `type X = ...;` (in a trait) | associated type | a configuration macro |
| `#[derive(...)]` / `#[component]` | compile-time code generation | nothing comparable; far stronger than macros |
| `unsafe { ... }` | the compiler cannot verify memory safety here; the author vouches | ordinary C, but fenced off |
| `Box::leak(x)` | heap object to `'static` reference, never freed | `AllocatePool` without `FreePool` |
| `Once<T>` / `spin::Mutex` / `TplMutex` | write-once / spinlock / TPL lock | NULL-checked global / `CoreAcquireLock` |
| `#[repr(C)]` | C struct layout | the default layout |
| `extern "efiapi" fn` | UEFI calling convention | `EFIAPI` |
| `*const T` / `*mut T` | raw pointers; dereferencing is `unsafe` | pointers |
| `'static` / `'a` | lifetime annotations; references cannot dangle | nothing; discipline |
| `log::info!("{x}")` | formatted logging | `DEBUG((DEBUG_INFO, "%x", x))` |
| `env!("CARGO_PKG_VERSION")` | read Cargo.toml at compile time | a `-D` define |

When a construct is unclear, read the book's `dev/principles/` pages first (`unsafe.md`, `ffi.md`,
`error-handling.md`); they are Patina's own conventions and more relevant than a general Rust tutorial.

## Appendix B: Error lookup table

| Symptom | Cause | Fix |
| --- | --- | --- |
| `'GenSec' is not recognized` | `CLANGPDB_DLL` undefined → leading `;` in PATH → cmd.exe on Windows 11 finds nothing | set `CLANGPDB_DLL` (`build_q35.ps1` does) |
| `-Werror,-Wunused-but-set-global` | new warning in clang 23 | use LLVM 21 (`setup.ps1` does) |
| `Filename too long` while cloning MU_BASECORE | Windows 260-character path limit | `core.longpaths=true`, short checkout path (`setup.ps1` does) |
| `Components not dispatched: ... Service<dyn X> not available` | nobody produced the service | check the producer is registered and not itself blocked |
| `Components not dispatched: ... Config<X> ...` | config never registered, or never locked | `add.config` in `ComponentInfo::configs`; check for a `ConfigMut<X>` writer that never ran |
| `Driver X found but not dispatched` | C driver depex unsatisfied | same investigation as on Tiano |
| `Missing architectural protocol: ..., "Timer"` | the driver providing it is not in the FV or did not dispatch | check FDF and depex |
| `No parser registered for HOB: GuidHob { ... }` | warning: a GUID HOB nobody consumes | add a `FromHob` if needed, otherwise ignore |
| `DXE Core failed to start: ...` then straight to BDS | some step of `start_dispatcher` returned `Err` | find the first `ERROR` above it |
| QEMU exits immediately with a non-zero code | panic → `qemu_fail` | look for `panicked at` and `StackTrace` above |
| `cargo make` cannot find target `x86_64-unknown-uefi` | rustup lacks the UEFI target | run `rustup show` inside `patina-dxe-core-qemu` |
| `#[component]` compile error about conflicting parameters | `Config<T>` with `ConfigMut<T>`, or `&mut Storage` with `Config` | use `Commands` |

## Appendix C: Glossary

| English | 中文 | Notes |
| --- | --- | --- |
| Component | 组件 | a Rust module statically linked into the core that declares dependencies through parameters |
| Service | 服务 | the interface between Rust components, `Service<dyn Trait>` |
| Config / ConfigMut | 配置 | platform-injected read-only / writable data with lock semantics |
| Storage | 存储 | the dispatcher's container for all configs, services and HOBs |
| Commands | 命令队列 | deferred modifications to Storage, applied after the component returns |
| Dependency injection | 依赖注入 | the framework passes dependencies to a component based on parameter types |
| Dispatcher | 分发器 | two of them: the component dispatcher (Rust) and the PI dispatcher (C drivers) |
| GCD, Global Coherency Domain | 全局一致性域 | the PI memory/IO space manager |
| HOB, Hand-Off Block | 交接块 | data PEI passes to DXE |
| FV, Firmware Volume | 固件卷 | a container of drivers |
| Section Extractor | 段解压器 | decompresses compressed sections inside FVs |
| Architectural Protocol | 架构协议 | the 13 protocols PI requires in DXE |
| TPL, Task Priority Level | 任务优先级 | UEFI's interrupt-masking levels |
| On-system test | 片上测试 | a `#[patina_test]` that runs inside the firmware |
| Procedural macro | 过程宏 | compile-time code generation, e.g. `#[component]` |
| Trait object | trait 对象 | `dyn Trait`, runtime polymorphism |
| Associated type | 关联类型 | a type named by the trait's implementor |
| Monomorphization | 单态化 | generics expanded per concrete type |
