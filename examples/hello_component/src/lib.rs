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

/// On-system tests (learning guide chapter 5, exercise 4).
///
/// `#[patina_test]` functions are collected by the `TestRunner` component that the Q35 platform already registers.
/// They take the same injected parameters as components. `#[on(event = READY_TO_BOOT)]` delays them until every
/// component and driver has dispatched, so the service is guaranteed to exist. Results show up in the console as
/// `hello_component::tests::<name> ... ok` under "Patina on-system unit-test results".
mod tests {
    use super::{Greeting, GreetingConfig};
    use patina::{
        BinaryGuid,
        component::{params::Config, service::Service},
        standard::efi,
    };
    use patina_test::{patina_test, u_assert, u_assert_eq};

    /// The service exists and carries the name the platform registered.
    #[patina_test]
    #[on(event = BinaryGuid(efi::EVENT_GROUP_READY_TO_BOOT))]
    fn greeting_service_exists(greeting: Service<dyn Greeting>) -> patina_test::error::Result {
        let text = greeting.greeting();
        u_assert!(text.starts_with("Hello, "), "greeting does not start with 'Hello, '");
        u_assert!(text.contains("Patina learner"), "greeting does not contain the registered name");
        Ok(())
    }

    /// The number of exclamation marks matches the locked config value.
    #[patina_test]
    #[on(event = BinaryGuid(efi::EVENT_GROUP_READY_TO_BOOT))]
    fn greeting_matches_config(
        greeting: Service<dyn Greeting>,
        cfg: Config<GreetingConfig>,
    ) -> patina_test::error::Result {
        let text = greeting.greeting();
        let marks = text.chars().rev().take_while(|c| *c == '!').count();
        u_assert_eq!(marks, cfg.exclamation_marks, "exclamation mark count does not match GreetingConfig");
        Ok(())
    }
}
