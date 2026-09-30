//! Proc-macros for the Mydia plugin SDK.
//!
//! Re-exported as `mydia_plugin_sdk::plugin`; authors use it through the SDK, not
//! this crate directly.

use proc_macro::TokenStream;
use quote::quote;
use syn::parse::{Parse, ParseStream};
use syn::{parse_macro_input, Ident, ItemFn, Path, Token};

/// Optional macro arguments, comma-separated, any order, each at most once:
/// `on_schedule = f`, `on_http = p`, `setup = g`, `check_health = h`.
struct PluginArgs {
    on_schedule: Option<Path>,
    on_http: Option<Path>,
    setup: Option<Path>,
    check_health: Option<Path>,
}

impl Parse for PluginArgs {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let mut args = PluginArgs {
            on_schedule: None,
            on_http: None,
            setup: None,
            check_health: None,
        };

        while !input.is_empty() {
            let key: Ident = input.parse()?;
            input.parse::<Token![=]>()?;
            let path: Path = input.parse()?;

            let slot = match key.to_string().as_str() {
                "on_schedule" => &mut args.on_schedule,
                "on_http" => &mut args.on_http,
                "setup" => &mut args.setup,
                "check_health" => &mut args.check_health,
                _ => {
                    return Err(syn::Error::new(
                        key.span(),
                        "expected `on_schedule`, `on_http`, `setup` or `check_health`",
                    ))
                }
            };

            if slot.is_some() {
                return Err(syn::Error::new(key.span(), "argument given twice"));
            }

            *slot = Some(path);

            if !input.is_empty() {
                input.parse::<Token![,]>()?;
            }
        }

        Ok(args)
    }
}

/// Turn a plain handler function into a Mydia plugin component.
///
/// The annotated function must have the signature
/// `fn(mydia_plugin_sdk::types::Event) -> Result<String, String>`. The macro
/// implements the generated `Guest` trait by calling it and emits the
/// component export, so the author never writes the trait impl or the export
/// wiring.
///
/// Further handlers are named as optional, order-free arguments:
///
/// ```ignore
/// #[mydia_plugin_sdk::plugin(on_schedule = handle_tick, setup = handle_setup, check_health = handle_health)]
/// fn on_event(evt: mydia_plugin_sdk::types::Event) -> Result<String, String> {
///     Ok("{}".into())
/// }
///
/// fn handle_tick(tick: mydia_plugin_sdk::types::ScheduleTick) -> Result<String, String> {
///     Ok("{}".into())
/// }
///
/// fn handle_setup(
///     req: mydia_plugin_sdk::types::SetupRequest,
/// ) -> Result<mydia_plugin_sdk::types::SetupScreen, String> {
///     Err(format!("unknown step {}", req.step))
/// }
///
/// fn handle_health() -> Result<mydia_plugin_sdk::types::Health, String> {
///     Err("unreachable".into())
/// }
/// ```
///
/// A plugin that serves a page names an HTTP handler the same way:
///
/// ```ignore
/// #[mydia_plugin_sdk::plugin(on_http = handle_http)]
/// fn on_event(evt: mydia_plugin_sdk::types::Event) -> Result<String, String> {
///     Ok("{}".into())
/// }
///
/// fn handle_http(
///     req: mydia_plugin_sdk::types::PageRequest,
/// ) -> Result<mydia_plugin_sdk::types::PageResponse, String> {
///     Err("no routes".into())
/// }
/// ```
///
/// Without `on_schedule`, the generated `on-schedule` export returns an error,
/// so a plugin that declares a manifest schedule but forgets the handler fails
/// loudly rather than silently doing nothing. `on-http` behaves the same way,
/// as do `setup` and `check_health` (1.5.0): a plugin that declares
/// `setup: true` in its manifest but forgets the handler fails loudly.
#[proc_macro_attribute]
pub fn plugin(attr: TokenStream, item: TokenStream) -> TokenStream {
    let args = parse_macro_input!(attr as PluginArgs);
    let func = parse_macro_input!(item as ItemFn);
    let fn_name = &func.sig.ident;

    let on_schedule_body = match args.on_schedule {
        Some(path) => quote! { #path(tick) },
        None => quote! {
            ::core::result::Result::Err(
                ::std::string::String::from("on-schedule not implemented by this plugin"),
            )
        },
    };

    let on_http_body = match args.on_http {
        Some(path) => quote! { #path(req) },
        None => quote! {
            ::core::result::Result::Err(
                ::std::string::String::from("on-http not implemented by this plugin"),
            )
        },
    };

    let setup_body = match args.setup {
        Some(path) => quote! { #path(req) },
        None => quote! {
            ::core::result::Result::Err(
                ::std::string::String::from("setup not implemented by this plugin"),
            )
        },
    };

    let check_health_body = match args.check_health {
        Some(path) => quote! { #path() },
        None => quote! {
            ::core::result::Result::Err(
                ::std::string::String::from("check-health not implemented by this plugin"),
            )
        },
    };

    let expanded = quote! {
        #func

        #[doc(hidden)]
        struct __MydiaPluginImpl;

        impl ::mydia_plugin_sdk::Guest for __MydiaPluginImpl {
            fn on_event(
                evt: ::mydia_plugin_sdk::types::Event,
            ) -> ::core::result::Result<::std::string::String, ::std::string::String> {
                #fn_name(evt)
            }

            fn on_schedule(
                tick: ::mydia_plugin_sdk::types::ScheduleTick,
            ) -> ::core::result::Result<::std::string::String, ::std::string::String> {
                let _ = &tick;
                #on_schedule_body
            }

            fn setup(
                req: ::mydia_plugin_sdk::types::SetupRequest,
            ) -> ::core::result::Result<
                ::mydia_plugin_sdk::types::SetupScreen,
                ::std::string::String,
            > {
                let _ = &req;
                #setup_body
            }

            fn check_health() -> ::core::result::Result<
                ::mydia_plugin_sdk::types::Health,
                ::std::string::String,
            > {
                #check_health_body
            }
        }

        impl ::mydia_plugin_sdk::PageGuest for __MydiaPluginImpl {
            fn on_http(
                req: ::mydia_plugin_sdk::types::PageRequest,
            ) -> ::core::result::Result<::mydia_plugin_sdk::types::PageResponse, ::std::string::String> {
                let _ = &req;
                #on_http_body
            }
        }

        ::mydia_plugin_sdk::export_plugin!(__MydiaPluginImpl);
    };

    expanded.into()
}
