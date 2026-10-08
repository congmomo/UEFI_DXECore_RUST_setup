# hello_component

Companion example for chapter 5 of the learning guide
([English](../../docs/learning-guide.en.md#5-your-first-component) ·
[中文](../../docs/learning-guide.zh.md#5-动手写第一个组件)).

Two Patina components, one service, one config:

- `HelloGreeter` reads `Config<GreetingConfig>` and produces `Service<dyn Greeting>` through `Commands`.
- `GreetingConsumer` consumes the service. It is registered *first* on purpose; the dispatcher still runs it second.

```powershell
.\apply.ps1                                   # wire into ..\..\patina-dxe-core-qemu (Cargo.toml + bin\q35_dxe_core.rs)
..\..\build_q35.ps1 -LocalCore -Headless -Run # build Rust core + firmware, boot headless
.\apply.ps1 -Revert                           # restore the upstream files
```

Expected console lines (see `../../logs/qemu_q35_hello_component.log`):

```
Dispatching hello_component::HelloGreeter
[hello_component] Hello, Patina learner!!!  (config says 3 exclamation marks)
Dispatching hello_component::GreetingConsumer
[hello_component] consumer got: Hello, Patina learner!!!
```

---

学习指导第 5 章的配套示例。两个组件、一个服务、一个配置：`HelloGreeter` 读配置并生产服务，
`GreetingConsumer` 消费服务。消费者故意先注册，分发器仍然让它后跑。
`apply.ps1` 把示例接进 `patina-dxe-core-qemu`，`-Revert` 还原；预期输出见上。
