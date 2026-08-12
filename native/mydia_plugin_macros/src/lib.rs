//! Proc-macros for the Mydia plugin SDK.
//!
//! Re-exported as `mydia_plugin_sdk::plugin`; authors use it through the SDK, not
//! this crate directly.

use proc_macro::TokenStream;
use quote::quote;
use syn::parse::{Parse, ParseStream};
use syn::{parse_macro_input, Ident, ItemFn, Path, Token};

/// Optional macro arguments. `#[mydia_plugin_sdk::plugin]` takes no args (event-only); a
/// scheduled plugin passes `#[mydia::plugin(on_schedule = handle_tick)]` naming
/// a second handler `fn(ScheduleTick) -> Result<String, String>`.
struct PluginArgs {
    on_schedule: Option<Path>,
    on_connect: Option<Path>,
}

impl Parse for PluginArgs {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let mut on_schedule = None;
        let mut on_connect = None;

        if input.is_empty() {
            return Ok(PluginArgs {
                on_schedule,
                on_connect,
            });
        }

        while !input.is_empty() {
            let key: Ident = input.parse()?;

            if key == "on_schedule" {
                if on_schedule.is_some() {
                    return Err(syn::Error::new(
                        key.span(),
                        "duplicate `on_schedule` argument",
                    ));
                }
                input.parse::<Token![=]>()?;
                on_schedule = Some(input.parse()?);
            } else if key == "on_connect" {
                if on_connect.is_some() {
                    return Err(syn::Error::new(
                        key.span(),
                        "duplicate `on_connect` argument",
                    ));
                }
                input.parse::<Token![=]>()?;
                on_connect = Some(input.parse()?);
            } else {
                return Err(syn::Error::new(
                    key.span(),
                    "expected `on_schedule = <handler fn>` or `on_connect = <handler fn>`",
                ));
            }

            if input.is_empty() {
                break;
            }

            input.parse::<Token![,]>()?;
        }

        Ok(PluginArgs {
            on_schedule,
            on_connect,
        })
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
/// A scheduled plugin additionally names a second handler:
///
/// ```ignore
/// #[mydia_plugin_sdk::plugin(on_schedule = handle_tick)]
/// fn on_event(evt: mydia_plugin_sdk::types::Event) -> Result<String, String> {
///     Ok("{}".into())
/// }
///
/// fn handle_tick(tick: mydia_plugin_sdk::types::ScheduleTick) -> Result<String, String> {
///     Ok("{}".into())
/// }
/// ```
///
/// Without `on_schedule`, the generated `on-schedule` export returns an error,
/// so a plugin that declares a manifest schedule but forgets the handler fails
/// loudly rather than silently doing nothing.
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

    let on_connect_body = match args.on_connect {
        Some(path) => quote! { #path(req) },
        None => quote! {
            ::core::result::Result::Err(
                ::std::string::String::from("this plugin has no interactive connect flow"),
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

            fn on_connect(
                req: ::mydia_plugin_sdk::types::ConnectRequest,
            ) -> ::core::result::Result<
                ::mydia_plugin_sdk::types::ConnectResponse,
                ::std::string::String,
            > {
                let _ = &req;
                #on_connect_body
            }
        }

        ::mydia_plugin_sdk::export_plugin!(__MydiaPluginImpl);
    };

    expanded.into()
}
