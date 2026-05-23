//! Framework-level UI primitives.
//!
//! Mirrors `lib/mydia_web/components/core_components.ex`'s public API
//! surface — button, input, modal, table, icon, flash. `DaisyUI` 4.x
//! classes are used directly without a wrapper layer, matching the
//! Phoenix discipline. Each component is a Dioxus function component
//! reusable from any page or domain component.
//!
//! Icons: the Phoenix `<.icon name="hero-x-mark" />` convention maps
//! to a small SVG dispatch here. U22 ships the icons the layout and
//! hello page need; new icons are added on demand (the goal is not
//! to ship every heroicon, just the ones our UI references).

use dioxus::prelude::*;

// ---------- Button ----------

#[derive(Props, Clone, PartialEq)]
pub struct ButtonProps {
    #[props(default)]
    pub variant: ButtonVariant,
    #[props(default)]
    pub size: ButtonSize,
    #[props(default)]
    pub class: String,
    #[props(default)]
    pub disabled: bool,
    #[props(default)]
    pub onclick: Option<EventHandler<MouseEvent>>,
    // `button` by default — set to `"submit"` when the button must
    // trigger the surrounding form's onsubmit handler. HTML defaults
    // form-nested buttons to submit, but Dioxus renders the attribute
    // explicitly, so we keep parity by being explicit here too.
    #[props(default = String::from("button"))]
    pub r#type: String,
    pub children: Element,
}

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum ButtonVariant {
    #[default]
    Primary,
    Secondary,
    Accent,
    Ghost,
    Outline,
    Error,
}

impl ButtonVariant {
    fn class(self) -> &'static str {
        match self {
            Self::Primary => "btn-primary",
            Self::Secondary => "btn-secondary",
            Self::Accent => "btn-accent",
            Self::Ghost => "btn-ghost",
            Self::Outline => "btn-outline",
            Self::Error => "btn-error",
        }
    }
}

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum ButtonSize {
    Xs,
    Sm,
    #[default]
    Md,
    Lg,
}

impl ButtonSize {
    fn class(self) -> &'static str {
        match self {
            Self::Xs => "btn-xs",
            Self::Sm => "btn-sm",
            Self::Md => "",
            Self::Lg => "btn-lg",
        }
    }
}

#[component]
pub fn Button(props: ButtonProps) -> Element {
    let variant = props.variant.class();
    let size = props.size.class();
    let extra = props.class.clone();
    let onclick = props.onclick;
    let btn_type = props.r#type.clone();

    rsx! {
        button {
            r#type: "{btn_type}",
            class: "btn {variant} {size} {extra}",
            disabled: props.disabled,
            onclick: move |evt| {
                if let Some(handler) = onclick.as_ref() {
                    handler.call(evt);
                }
            },
            {props.children}
        }
    }
}

// ---------- Input ----------

#[derive(Props, Clone, PartialEq)]
pub struct InputProps {
    pub name: String,
    #[props(default = String::from("text"))]
    pub r#type: String,
    #[props(default)]
    pub value: String,
    #[props(default)]
    pub label: Option<String>,
    #[props(default)]
    pub placeholder: Option<String>,
    #[props(default)]
    pub class: String,
    #[props(default)]
    pub error: Option<String>,
    #[props(default)]
    pub disabled: bool,
    #[props(default)]
    pub required: bool,
    // Without this, the rendered `<input>` is purely one-way (signal →
    // DOM) and callers can't observe what the user typed. Most pages
    // pair this with `move |e| my_signal.set(e.value())`.
    #[props(default)]
    pub oninput: Option<EventHandler<FormEvent>>,
}

/// Text/email/password input with `DaisyUI` `input-bordered` styling. The
/// `field` prop on Phoenix's `<.input>` (which carries form-state via
/// `Phoenix.HTML.FormField`) doesn't have a 1:1 Dioxus analog — server
/// functions in U24+ surface validation state explicitly, so callers
/// pass an `error` string for now and the component renders the label
/// + error inline.
#[component]
pub fn Input(props: InputProps) -> Element {
    let has_error = props.error.is_some();
    let input_class = if has_error {
        "input input-bordered input-error w-full"
    } else {
        "input input-bordered w-full"
    };
    let oninput = props.oninput;

    rsx! {
        label { class: "form-control w-full {props.class}",
            if let Some(label) = props.label.as_ref() {
                div { class: "label",
                    span { class: "label-text", "{label}" }
                }
            }
            input {
                r#type: "{props.r#type}",
                name: "{props.name}",
                value: "{props.value}",
                placeholder: props.placeholder.as_deref().unwrap_or(""),
                disabled: props.disabled,
                required: props.required,
                class: "{input_class}",
                oninput: move |evt| {
                    if let Some(handler) = oninput.as_ref() {
                        handler.call(evt);
                    }
                },
            }
            if let Some(err) = props.error.as_ref() {
                div { class: "label",
                    span { class: "label-text-alt text-error", "{err}" }
                }
            }
        }
    }
}

// ---------- Modal ----------

#[derive(Props, Clone, PartialEq)]
pub struct ModalProps {
    pub id: String,
    pub open: bool,
    #[props(default)]
    pub on_close: Option<EventHandler<()>>,
    pub children: Element,
}

#[component]
pub fn Modal(props: ModalProps) -> Element {
    let on_close = props.on_close;
    let id = props.id.clone();

    rsx! {
        dialog {
            id: "{id}",
            class: if props.open { "modal modal-open" } else { "modal" },
            div { class: "modal-box max-w-2xl",
                {props.children}
            }
            form {
                method: "dialog",
                class: "modal-backdrop",
                button {
                    r#type: "submit",
                    onclick: move |_| {
                        if let Some(handler) = on_close.as_ref() {
                            handler.call(());
                        }
                    },
                    "close"
                }
            }
        }
    }
}

// ---------- Icon ----------

#[derive(Props, Clone, PartialEq, Eq)]
pub struct IconProps {
    pub name: String,
    #[props(default = String::from("w-5 h-5"))]
    pub class: String,
}

/// Tiny SVG icon dispatch — Heroicons-shaped paths inlined per-name.
/// We carry only the icons our UI actually references; new icons are
/// added explicitly so a typo'd `name` doesn't silently render empty.
#[component]
pub fn Icon(props: IconProps) -> Element {
    let class = props.class.clone();
    let path = match props.name.as_str() {
        "menu" => "M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5",
        "home" => "M2.25 12 12 3l9.75 9M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-6h4.5v6h4.125c.621 0 1.125-.504 1.125-1.125V9.75",
        "sparkles" => "M9.813 15.904 9 18.75l-.813-2.846a4.5 4.5 0 0 0-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 0 0 3.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 0 0 3.09 3.09L15.75 12l-2.847.813a4.5 4.5 0 0 0-3.09 3.09ZM18.259 8.715 18 9.75l-.259-1.035a3.375 3.375 0 0 0-2.456-2.456L14.25 6l1.035-.259a3.375 3.375 0 0 0 2.456-2.456L18 2.25l.259 1.035a3.375 3.375 0 0 0 2.456 2.456L21.75 6l-1.035.259a3.375 3.375 0 0 0-2.456 2.456ZM16.894 20.567 16.5 21.75l-.394-1.183a2.25 2.25 0 0 0-1.423-1.423L13.5 18.75l1.183-.394a2.25 2.25 0 0 0 1.423-1.423l.394-1.183.394 1.183a2.25 2.25 0 0 0 1.423 1.423l1.183.394-1.183.394a2.25 2.25 0 0 0-1.423 1.423Z",
        "x-mark" => "M6 18 18 6M6 6l12 12",
        "exclamation-circle" => "M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z",
        "information-circle" => "m11.25 11.25.041-.02a.75.75 0 0 1 1.063.852l-.708 2.836a.75.75 0 0 0 1.063.853l.041-.021M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9-3.75h.008v.008H12V8.25Z",
        "user" => "M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z",
        "film" => "M3 4.5h18M3 9h18M3 13.5h18M3 18h18M7.5 4.5v15m9-15v15M4.5 4.5h15a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18V6a1.5 1.5 0 0 1 1.5-1.5Z",
        "tv" => "M6 20.25h12m-7.5-3v3m3-3v3m-10.125-3h17.25c.621 0 1.125-.504 1.125-1.125V4.875c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125Z",
        _ => {
            tracing::warn!(name = %props.name, "unknown icon");
            ""
        }
    };

    rsx! {
        svg {
            xmlns: "http://www.w3.org/2000/svg",
            fill: "none",
            view_box: "0 0 24 24",
            stroke_width: "1.5",
            stroke: "currentColor",
            class: "{class}",
            "aria-hidden": "true",
            path {
                stroke_linecap: "round",
                stroke_linejoin: "round",
                d: "{path}"
            }
        }
    }
}

// ---------- Flash group ----------

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum FlashKind {
    #[default]
    Info,
    Success,
    Warning,
    Error,
}

impl FlashKind {
    fn alert_class(self) -> &'static str {
        match self {
            Self::Info => "alert alert-info",
            Self::Success => "alert alert-success",
            Self::Warning => "alert alert-warning",
            Self::Error => "alert alert-error",
        }
    }

    fn icon(self) -> &'static str {
        match self {
            Self::Info | Self::Success => "information-circle",
            Self::Warning | Self::Error => "exclamation-circle",
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct FlashProps {
    pub kind: FlashKind,
    pub message: String,
    #[props(default)]
    pub title: Option<String>,
}

#[component]
pub fn Flash(props: FlashProps) -> Element {
    rsx! {
        div { role: "alert", class: "{props.kind.alert_class()}",
            Icon { name: props.kind.icon().to_string(), class: "w-6 h-6 shrink-0".to_string() }
            div { class: "flex flex-col",
                if let Some(title) = props.title.as_ref() {
                    span { class: "font-semibold", "{title}" }
                }
                span { "{props.message}" }
            }
        }
    }
}

#[derive(Clone, PartialEq, Debug)]
pub struct FlashMessage {
    pub kind: FlashKind,
    pub title: Option<String>,
    pub message: String,
}

#[derive(Props, Clone, PartialEq)]
pub struct FlashGroupProps {
    #[props(default)]
    pub flashes: Vec<FlashMessage>,
}

/// Renders a vertical stack of flash messages, positioned top-right.
/// The mountpoint is fixed in the layout (`AppShell`); pages and
/// server-fn responses push messages here. Phoenix's `<.flash_group>`
/// lives in `Layouts` per the v1.8 convention; this Dioxus analog is
/// usable from any component.
#[component]
pub fn FlashGroup(props: FlashGroupProps) -> Element {
    if props.flashes.is_empty() {
        return rsx! {};
    }
    rsx! {
        div { class: "toast toast-top toast-end z-50",
            for flash in props.flashes.iter().cloned() {
                Flash {
                    key: "{flash.kind:?}-{flash.message}",
                    kind: flash.kind,
                    title: flash.title.clone(),
                    message: flash.message.clone()
                }
            }
        }
    }
}

// ---------- Tests ----------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn button_variant_class_maps_to_daisyui() {
        assert_eq!(ButtonVariant::Primary.class(), "btn-primary");
        assert_eq!(ButtonVariant::Secondary.class(), "btn-secondary");
        assert_eq!(ButtonVariant::Accent.class(), "btn-accent");
        assert_eq!(ButtonVariant::Ghost.class(), "btn-ghost");
        assert_eq!(ButtonVariant::Outline.class(), "btn-outline");
        assert_eq!(ButtonVariant::Error.class(), "btn-error");
    }

    #[test]
    fn button_size_class_maps_to_daisyui() {
        assert_eq!(ButtonSize::Xs.class(), "btn-xs");
        assert_eq!(ButtonSize::Sm.class(), "btn-sm");
        assert_eq!(ButtonSize::Md.class(), "");
        assert_eq!(ButtonSize::Lg.class(), "btn-lg");
    }

    #[test]
    fn flash_kind_alert_class_maps_to_daisyui() {
        assert_eq!(FlashKind::Info.alert_class(), "alert alert-info");
        assert_eq!(FlashKind::Success.alert_class(), "alert alert-success");
        assert_eq!(FlashKind::Warning.alert_class(), "alert alert-warning");
        assert_eq!(FlashKind::Error.alert_class(), "alert alert-error");
    }
}
