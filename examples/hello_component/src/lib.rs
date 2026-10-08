//! Learning-guide example components for the Patina DXE Core.
//!
//! Three things are demonstrated, in the order the learning guide introduces them:
//!
//! 1. [`HelloGreeter`]  - a component with state (`name`) that reads a platform [`Config`] value and
//!    then *produces* a service (`dyn Greeting`) through [`Commands`].
//! 2. [`GreetingConsumer`] - a component that *consumes* that service. The dispatcher will not run it
//!    until the service exists, so it always logs after `HelloGreeter`, whatever order they were
//!    registered in.
//! 3. [`GreetingConfig`] - a plain `Default` struct used as the config type.
//!
//! Wire it into `patina-dxe-core-qemu/bin/q35_dxe_core.rs` (see `apply.ps1`):
//!
//! ```rust,ignore
//! fn configs(mut add: Add<Config>) {
//!     add.config(hello_component::GreetingConfig { exclamation_marks: 3 });
//! }
//! fn components(mut add: Add<Component>) {
//!     add.component(hello_component::GreetingConsumer);          // registered first on purpose
//!     add.component(hello_component::HelloGreeter::new("Patina learner"));
//! }
//! ```
//!
//! Expected console output (debugcon) during "Dispatching Drivers":
//!
//! ```text
//! Dispatching hello_component::HelloGreeter
//! [hello_component] Hello, Patina learner!!!  (config says 3 exclamation marks)
//! Dispatching hello_component::GreetingConsumer
//! [hello_component] consumer got: Hello, Patina learner!!!
//! ```
#![no_std]

extern crate alloc;
use alloc::{format, string::String};

use patina::{
    component::{
        component,
        params::{Commands, Config},
        service::{IntoService, Service},
    },
    error::Result,
};

/// Platform-provided configuration for the greeter. `Config<T>` requires `T: Default`.
#[derive(Debug, Default, Clone, Copy)]
pub struct GreetingConfig {
    /// How enthusiastic the greeting is.
    pub exclamation_marks: usize,
}

/// The service interface. Consumers only see this trait, never the concrete type.
/// Services are shared read-only, so methods take `&self`.
pub trait Greeting {
    /// Returns the rendered greeting.
    fn greeting(&self) -> String;
}

/// Concrete implementation of [`Greeting`]. The derive registers it in Storage as `dyn Greeting`.
#[derive(IntoService)]
#[service(dyn Greeting)]
struct GreetingImpl {
    text: String,
}

impl Greeting for GreetingImpl {
    fn greeting(&self) -> String {
        self.text.clone()
    }
}

/// Component 1: has state, reads a config, produces a service.
pub struct HelloGreeter {
    name: &'static str,
}

impl HelloGreeter {
    /// Creates the greeter for `name`.
    pub fn new(name: &'static str) -> Self {
        Self { name }
    }
}

#[component]
impl HelloGreeter {
    /// `Config<GreetingConfig>` is only handed out once the config is locked, i.e. after every
    /// component that wanted `ConfigMut<GreetingConfig>` has run. `Commands` defers the service
    /// registration until this entry point returns, which avoids borrowing Storage mutably here.
    fn entry_point(self, cfg: Config<GreetingConfig>, mut commands: Commands) -> Result<()> {
        let marks = "!".repeat(cfg.exclamation_marks);
        let text = format!("Hello, {}{}", self.name, marks);
        log::info!("[hello_component] {text}  (config says {} exclamation marks)", cfg.exclamation_marks);

        commands.add_service(GreetingImpl { text });
        Ok(())
    }
}

/// Component 2: consumes the service. Not dispatched until `dyn Greeting` has been produced.
#[derive(Default)]
pub struct GreetingConsumer;

#[component]
impl GreetingConsumer {
    fn entry_point(self, greeting: Service<dyn Greeting>) -> Result<()> {
        log::info!("[hello_component] consumer got: {}", greeting.greeting());
        Ok(())
    }
}
