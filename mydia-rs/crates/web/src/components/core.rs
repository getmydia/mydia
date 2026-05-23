//! Framework-level UI primitives.
//!
//! Mirrors `lib/mydia_web/components/core_components.ex`'s public API
//! surface — button, input, modal, table, header, badge, progress bar,
//! icon, flash. `DaisyUI` 4.x classes are used directly without a wrapper
//! layer, matching the Phoenix discipline. Each component is a Dioxus
//! function component reusable from any page or domain component.
//!
//! Icons: the Phoenix `<.icon name="hero-x-mark" />` convention maps
//! to a small SVG dispatch here. We carry the icons the layout + media
//! pages reference; new icons are added explicitly so a typo'd `name`
//! doesn't silently render empty.

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
    /// Renders a `loading loading-spinner` inline at the start of the
    /// button label and forces `disabled` to `true`. Mirrors the visual
    /// pattern Phoenix uses for in-flight submits.
    #[props(default)]
    pub loading: bool,
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
    Warning,
    Success,
    Info,
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
            Self::Warning => "btn-warning",
            Self::Success => "btn-success",
            Self::Info => "btn-info",
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
    let disabled = props.disabled || props.loading;
    let loading = props.loading;

    rsx! {
        button {
            r#type: "{btn_type}",
            class: "btn {variant} {size} {extra}",
            disabled: disabled,
            onclick: move |evt| {
                if let Some(handler) = onclick.as_ref() {
                    handler.call(evt);
                }
            },
            if loading {
                span { class: "loading loading-spinner loading-sm" }
            }
            {props.children}
        }
    }
}

// ---------- Badge ----------

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum BadgeVariant {
    #[default]
    Neutral,
    Primary,
    Secondary,
    Accent,
    Info,
    Success,
    Warning,
    Error,
    Ghost,
    Outline,
}

impl BadgeVariant {
    fn class(self) -> &'static str {
        match self {
            Self::Neutral => "",
            Self::Primary => "badge-primary",
            Self::Secondary => "badge-secondary",
            Self::Accent => "badge-accent",
            Self::Info => "badge-info",
            Self::Success => "badge-success",
            Self::Warning => "badge-warning",
            Self::Error => "badge-error",
            Self::Ghost => "badge-ghost",
            Self::Outline => "badge-outline",
        }
    }
}

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum BadgeSize {
    Xs,
    Sm,
    #[default]
    Md,
    Lg,
}

impl BadgeSize {
    fn class(self) -> &'static str {
        match self {
            Self::Xs => "badge-xs",
            Self::Sm => "badge-sm",
            Self::Md => "",
            Self::Lg => "badge-lg",
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct BadgeProps {
    #[props(default)]
    pub variant: BadgeVariant,
    #[props(default)]
    pub size: BadgeSize,
    #[props(default)]
    pub class: String,
    pub children: Element,
}

/// `DaisyUI` `badge` element with optional variant and size modifiers.
/// Mirrors the Phoenix `library_components.ex` badge usage scattered
/// across the media pages.
#[component]
pub fn Badge(props: BadgeProps) -> Element {
    let variant = props.variant.class();
    let size = props.size.class();
    let extra = props.class.clone();
    rsx! {
        span { class: "badge {variant} {size} {extra}",
            {props.children}
        }
    }
}

// ---------- Header ----------

#[derive(Props, Clone, PartialEq)]
pub struct HeaderProps {
    pub title: String,
    #[props(default)]
    pub subtitle: Option<Element>,
    #[props(default)]
    pub actions: Option<Element>,
    #[props(default)]
    pub class: String,
}

/// Page header — title (+ optional subtitle) on the left, optional
/// actions slot on the right. Drop-in for `<.header>` in
/// `core_components.ex`.
#[component]
pub fn Header(props: HeaderProps) -> Element {
    let has_actions = props.actions.is_some();
    let layout = if has_actions {
        "flex items-center justify-between gap-6 pb-4"
    } else {
        "pb-4"
    };
    let extra = props.class.clone();

    rsx! {
        header { class: "{layout} {extra}",
            div {
                h1 { class: "text-lg font-semibold leading-8", "{props.title}" }
                if let Some(subtitle) = props.subtitle {
                    p { class: "text-sm text-base-content/70", {subtitle} }
                }
            }
            if let Some(actions) = props.actions {
                div { class: "flex-none", {actions} }
            }
        }
    }
}

// ---------- Progress bar ----------

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum ProgressVariant {
    #[default]
    Neutral,
    Primary,
    Secondary,
    Accent,
    Info,
    Success,
    Warning,
    Error,
}

impl ProgressVariant {
    fn class(self) -> &'static str {
        match self {
            Self::Neutral => "",
            Self::Primary => "progress-primary",
            Self::Secondary => "progress-secondary",
            Self::Accent => "progress-accent",
            Self::Info => "progress-info",
            Self::Success => "progress-success",
            Self::Warning => "progress-warning",
            Self::Error => "progress-error",
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct ProgressBarProps {
    /// 0–100. Clamped on render so callers don't need to defensively cap.
    pub value: f32,
    #[props(default)]
    pub variant: ProgressVariant,
    #[props(default)]
    pub label: Option<String>,
    #[props(default = String::from("w-full"))]
    pub class: String,
}

/// `DaisyUI` `progress` element with optional label rendered above the bar.
#[component]
pub fn ProgressBar(props: ProgressBarProps) -> Element {
    let value = props.value.clamp(0.0, 100.0);
    let variant = props.variant.class();
    let extra = props.class.clone();
    rsx! {
        div { class: "flex flex-col gap-1 {extra}",
            if let Some(label) = props.label.as_ref() {
                div { class: "text-xs opacity-70", "{label}" }
            }
            progress {
                class: "progress {variant}",
                value: "{value}",
                max: "100",
            }
        }
    }
}

// ---------- Input ----------

#[derive(Props, Clone, PartialEq)]
pub struct InputProps {
    pub name: String,
    /// Input type. Recognized values mirror Phoenix's `<.input>`:
    /// `text`, `email`, `password`, `number`, `search`, `tel`, `url`,
    /// `date`, `datetime-local`, `time`, `month`, `week`, `color`,
    /// `file`, `range`, `checkbox`, `radio`, `select`, `textarea`.
    #[props(default = String::from("text"))]
    pub r#type: String,
    #[props(default)]
    pub id: Option<String>,
    #[props(default)]
    pub value: String,
    #[props(default)]
    pub checked: bool,
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
    #[props(default)]
    pub multiple: bool,
    #[props(default)]
    pub min: Option<String>,
    #[props(default)]
    pub max: Option<String>,
    #[props(default)]
    pub step: Option<String>,
    #[props(default)]
    pub rows: Option<u32>,
    #[props(default)]
    pub accept: Option<String>,
    /// For `type="select"`: `(value, label)` pairs.
    #[props(default)]
    pub options: Vec<(String, String)>,
    /// For `type="select"`: optional placeholder option rendered first
    /// with an empty value.
    #[props(default)]
    pub prompt: Option<String>,
    // Without this, the rendered input is purely one-way (signal →
    // DOM) and callers can't observe what the user typed. Most pages
    // pair this with `move |e| my_signal.set(e.value())`.
    #[props(default)]
    pub oninput: Option<EventHandler<FormEvent>>,
    #[props(default)]
    pub onchange: Option<EventHandler<FormEvent>>,
}

/// Form input dispatching on `r#type` — text/email/password/etc. share
/// one branch; checkbox, radio, select, textarea, and range each get
/// their own. The variant-dispatch shape mirrors Phoenix's `input/1`
/// `def`-clauses. The `field` form-state plumbing in Phoenix's
/// `<.input>` doesn't translate to Dioxus signals directly — callers
/// pass an `error` string and wire `oninput` themselves.
#[component]
pub fn Input(props: InputProps) -> Element {
    let kind = props.r#type.as_str();
    match kind {
        "checkbox" => render_checkbox(props),
        "radio" => render_radio(props),
        "select" => render_select(props),
        "textarea" => render_textarea(props),
        "range" => render_range(props),
        _ => render_default(props),
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_default(props: InputProps) -> Element {
    let kind = props.r#type.clone();
    let has_error = props.error.is_some();
    let extra_class = props.class.clone();
    let base = if extra_class.is_empty() {
        "input input-bordered w-full".to_string()
    } else {
        extra_class
    };
    let input_class = if has_error {
        format!("{base} input-error")
    } else {
        base
    };
    let oninput = props.oninput;
    let onchange = props.onchange;
    let id = props.id.clone().unwrap_or_else(|| props.name.clone());

    rsx! {
        div { class: "fieldset mb-2 w-full",
            label {
                if let Some(label) = props.label.as_ref() {
                    span { class: "label mb-1 text-sm font-medium text-base-content/80", "{label}" }
                }
                input {
                    r#type: "{kind}",
                    id: "{id}",
                    name: "{props.name}",
                    value: "{props.value}",
                    placeholder: props.placeholder.as_deref().unwrap_or(""),
                    disabled: props.disabled,
                    required: props.required,
                    min: props.min.clone().unwrap_or_default(),
                    max: props.max.clone().unwrap_or_default(),
                    step: props.step.clone().unwrap_or_default(),
                    accept: props.accept.clone().unwrap_or_default(),
                    class: "{input_class}",
                    oninput: move |evt| {
                        if let Some(handler) = oninput.as_ref() {
                            handler.call(evt);
                        }
                    },
                    onchange: move |evt| {
                        if let Some(handler) = onchange.as_ref() {
                            handler.call(evt);
                        }
                    },
                }
            }
            if let Some(err) = props.error.as_ref() {
                {render_error(err)}
            }
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_checkbox(props: InputProps) -> Element {
    let extra = props.class.clone();
    let base = if extra.is_empty() {
        "checkbox checkbox-sm".to_string()
    } else {
        extra
    };
    let onchange = props.onchange;
    let id = props.id.clone().unwrap_or_else(|| props.name.clone());

    rsx! {
        div { class: "fieldset mb-2",
            label { class: "flex items-center gap-2 cursor-pointer",
                input {
                    r#type: "checkbox",
                    id: "{id}",
                    name: "{props.name}",
                    value: "true",
                    checked: props.checked,
                    disabled: props.disabled,
                    class: "{base}",
                    onchange: move |evt| {
                        if let Some(handler) = onchange.as_ref() {
                            handler.call(evt);
                        }
                    },
                }
                if let Some(label) = props.label.as_ref() {
                    span { class: "label-text", "{label}" }
                }
            }
            if let Some(err) = props.error.as_ref() {
                {render_error(err)}
            }
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_radio(props: InputProps) -> Element {
    let extra = props.class.clone();
    let base = if extra.is_empty() {
        "radio radio-sm".to_string()
    } else {
        extra
    };
    let onchange = props.onchange;
    let id = props.id.clone().unwrap_or_else(|| props.name.clone());

    rsx! {
        div { class: "fieldset mb-2",
            label { class: "flex items-center gap-2 cursor-pointer",
                input {
                    r#type: "radio",
                    id: "{id}",
                    name: "{props.name}",
                    value: "{props.value}",
                    checked: props.checked,
                    disabled: props.disabled,
                    class: "{base}",
                    onchange: move |evt| {
                        if let Some(handler) = onchange.as_ref() {
                            handler.call(evt);
                        }
                    },
                }
                if let Some(label) = props.label.as_ref() {
                    span { class: "label-text", "{label}" }
                }
            }
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_select(props: InputProps) -> Element {
    let has_error = props.error.is_some();
    let extra = props.class.clone();
    let base = if extra.is_empty() {
        "select select-bordered w-full".to_string()
    } else {
        extra
    };
    let select_class = if has_error {
        format!("{base} select-error")
    } else {
        base
    };
    let onchange = props.onchange;
    let oninput = props.oninput;
    let current_value = props.value.clone();
    let id = props.id.clone().unwrap_or_else(|| props.name.clone());

    rsx! {
        div { class: "fieldset mb-2 w-full",
            label {
                if let Some(label) = props.label.as_ref() {
                    span { class: "label mb-1 text-sm font-medium text-base-content/80", "{label}" }
                }
                select {
                    id: "{id}",
                    name: "{props.name}",
                    multiple: props.multiple,
                    disabled: props.disabled,
                    required: props.required,
                    class: "{select_class}",
                    onchange: move |evt| {
                        if let Some(handler) = onchange.as_ref() {
                            handler.call(evt.clone());
                        }
                        if let Some(handler) = oninput.as_ref() {
                            handler.call(evt);
                        }
                    },
                    if let Some(prompt) = props.prompt.as_ref() {
                        option { value: "", "{prompt}" }
                    }
                    for (val, label) in props.options.iter() {
                        option {
                            value: "{val}",
                            selected: val.as_str() == current_value.as_str(),
                            "{label}"
                        }
                    }
                }
            }
            if let Some(err) = props.error.as_ref() {
                {render_error(err)}
            }
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_textarea(props: InputProps) -> Element {
    let has_error = props.error.is_some();
    let extra = props.class.clone();
    let base = if extra.is_empty() {
        "textarea textarea-bordered w-full".to_string()
    } else {
        extra
    };
    let area_class = if has_error {
        format!("{base} textarea-error")
    } else {
        base
    };
    let rows = props.rows.unwrap_or(4);
    let oninput = props.oninput;
    let onchange = props.onchange;
    let id = props.id.clone().unwrap_or_else(|| props.name.clone());
    let value = props.value.clone();

    rsx! {
        div { class: "fieldset mb-2 w-full",
            label {
                if let Some(label) = props.label.as_ref() {
                    span { class: "label mb-1 text-sm font-medium text-base-content/80", "{label}" }
                }
                textarea {
                    id: "{id}",
                    name: "{props.name}",
                    placeholder: props.placeholder.as_deref().unwrap_or(""),
                    disabled: props.disabled,
                    required: props.required,
                    rows: "{rows}",
                    class: "{area_class}",
                    oninput: move |evt| {
                        if let Some(handler) = oninput.as_ref() {
                            handler.call(evt);
                        }
                    },
                    onchange: move |evt| {
                        if let Some(handler) = onchange.as_ref() {
                            handler.call(evt);
                        }
                    },
                    "{value}"
                }
            }
            if let Some(err) = props.error.as_ref() {
                {render_error(err)}
            }
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_range(props: InputProps) -> Element {
    let extra = props.class.clone();
    let base = if extra.is_empty() {
        "range range-primary".to_string()
    } else {
        extra
    };
    let oninput = props.oninput;
    let onchange = props.onchange;
    let id = props.id.clone().unwrap_or_else(|| props.name.clone());

    rsx! {
        div { class: "fieldset mb-2 w-full",
            label {
                if let Some(label) = props.label.as_ref() {
                    span { class: "label mb-1 text-sm font-medium text-base-content/80", "{label}" }
                }
                input {
                    r#type: "range",
                    id: "{id}",
                    name: "{props.name}",
                    value: "{props.value}",
                    disabled: props.disabled,
                    min: props.min.clone().unwrap_or_else(|| "0".to_string()),
                    max: props.max.clone().unwrap_or_else(|| "100".to_string()),
                    step: props.step.clone().unwrap_or_else(|| "1".to_string()),
                    class: "{base}",
                    oninput: move |evt| {
                        if let Some(handler) = oninput.as_ref() {
                            handler.call(evt);
                        }
                    },
                    onchange: move |evt| {
                        if let Some(handler) = onchange.as_ref() {
                            handler.call(evt);
                        }
                    },
                }
            }
            if let Some(err) = props.error.as_ref() {
                {render_error(err)}
            }
        }
    }
}

fn render_error(err: &str) -> Element {
    let err = err.to_string();
    rsx! {
        p { class: "mt-1.5 flex gap-2 items-center text-sm text-error",
            Icon { name: "exclamation-circle".to_string(), class: "size-5".to_string() }
            "{err}"
        }
    }
}

// ---------- Modal ----------

#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum ModalSize {
    Sm,
    #[default]
    Md,
    Lg,
    Xl,
}

impl ModalSize {
    fn class(self) -> &'static str {
        match self {
            Self::Sm => "max-w-md",
            Self::Md => "max-w-lg",
            Self::Lg => "max-w-2xl",
            Self::Xl => "max-w-4xl",
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct ModalProps {
    pub id: String,
    pub open: bool,
    #[props(default)]
    pub size: ModalSize,
    /// Optional title slot, rendered as a bold header above the body.
    #[props(default)]
    pub title: Option<Element>,
    /// Optional actions slot, rendered in `modal-action` below the body.
    #[props(default)]
    pub actions: Option<Element>,
    #[props(default)]
    pub on_close: Option<EventHandler<()>>,
    pub children: Element,
}

/// `DaisyUI` `modal` dialog. Backdrop click + escape both close via the
/// optional `on_close` handler. Use the `title` and `actions` slots for
/// the canonical "title / body / actions" layout, or render the body
/// freely in `children` when you need a custom shape.
#[component]
pub fn Modal(props: ModalProps) -> Element {
    let on_close = props.on_close;
    let id = props.id.clone();
    let size = props.size.class();
    let dialog_class = if props.open {
        "modal modal-open"
    } else {
        "modal"
    };

    let on_close_for_kbd = on_close;
    let on_close_for_backdrop_btn = on_close;
    let on_close_for_close_btn = on_close;

    rsx! {
        dialog {
            id: "{id}",
            class: "{dialog_class}",
            onkeydown: move |evt| {
                if evt.key() == Key::Escape {
                    if let Some(handler) = on_close_for_kbd.as_ref() {
                        handler.call(());
                    }
                }
            },
            div { class: "modal-box {size}",
                if let Some(title) = props.title {
                    h3 { class: "font-bold text-lg mb-4", {title} }
                }
                if on_close_for_close_btn.is_some() {
                    button {
                        r#type: "button",
                        class: "btn btn-sm btn-circle btn-ghost absolute right-2 top-2",
                        onclick: move |_| {
                            if let Some(handler) = on_close_for_close_btn.as_ref() {
                                handler.call(());
                            }
                        },
                        Icon { name: "x-mark".to_string(), class: "w-5 h-5".to_string() }
                    }
                }
                div { class: "py-2",
                    {props.children}
                }
                if let Some(actions) = props.actions {
                    div { class: "modal-action", {actions} }
                }
            }
            form {
                method: "dialog",
                class: "modal-backdrop",
                button {
                    r#type: "submit",
                    onclick: move |_| {
                        if let Some(handler) = on_close_for_backdrop_btn.as_ref() {
                            handler.call(());
                        }
                    },
                    "close"
                }
            }
        }
    }
}

// ---------- Table ----------

#[derive(Props, Clone, PartialEq)]
pub struct TableProps {
    pub id: String,
    /// Header row content — pass `tr { th { ... } }` blocks. Kept open
    /// so callers can mix `<th>` styling per column without the
    /// component prescribing it.
    pub head: Element,
    /// Body rows. Pass `tr { ... }` blocks.
    pub body: Element,
    /// Rendered when `body` is logically empty. Callers decide; the
    /// component just renders whatever element is here in place of the
    /// `<tbody>` when `empty` is `Some(...)`.
    #[props(default)]
    pub empty: Option<Element>,
    /// Show the empty slot instead of the body. True = empty state.
    #[props(default)]
    pub is_empty: bool,
    #[props(default = String::from("table table-zebra"))]
    pub class: String,
}

/// Structural table wrapper mirroring Phoenix's `<.table>`. Sorting and
/// `phx-update="stream"` plumbing live one level up — this component
/// just renders the chrome.
#[component]
pub fn Table(props: TableProps) -> Element {
    let id = props.id.clone();
    let class = props.class.clone();
    rsx! {
        if props.is_empty && props.empty.is_some() {
            {props.empty}
        } else {
            div { class: "overflow-x-auto",
                table { class: "{class}",
                    thead { {props.head} }
                    tbody { id: "{id}", {props.body} }
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

/// Tiny SVG icon dispatch — Heroicons outline-shaped paths inlined
/// per-name. New icons are added explicitly so a typo'd `name` doesn't
/// silently render empty (we `tracing::warn!` and emit nothing).
#[component]
pub fn Icon(props: IconProps) -> Element {
    let class = props.class.clone();
    let (path, fill) = match props.name.as_str() {
        // Navigation + UI affordances
        "menu" | "bars-3" => ("M3.75 6.75h16.5M3.75 12h16.5m-16.5 5.25h16.5", false),
        "home" => (
            "M2.25 12 12 3l9.75 9M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-6h4.5v6h4.125c.621 0 1.125-.504 1.125-1.125V9.75",
            false,
        ),
        "x-mark" => ("M6 18 18 6M6 6l12 12", false),
        "plus" => ("M12 4.5v15m7.5-7.5h-15", false),
        "trash" => (
            "m14.74 9-.346 9m-4.788 0L9.26 9m9.968-3.21c.342.052.682.107 1.022.166m-1.022-.165L18.16 19.673a2.25 2.25 0 0 1-2.244 2.077H8.084a2.25 2.25 0 0 1-2.244-2.077L4.772 5.79m14.456 0a48.108 48.108 0 0 0-3.478-.397m-12 .562c.34-.059.68-.114 1.022-.165m0 0a48.11 48.11 0 0 1 3.478-.397m7.5 0v-.916c0-1.18-.91-2.164-2.09-2.201a51.964 51.964 0 0 0-3.32 0c-1.18.037-2.09 1.022-2.09 2.201v.916m7.5 0a48.667 48.667 0 0 0-7.5 0",
            false,
        ),
        "ellipsis-horizontal" => (
            "M6.75 12a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0ZM12.75 12a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0ZM18.75 12a.75.75 0 1 1-1.5 0 .75.75 0 0 1 1.5 0Z",
            false,
        ),
        "chevron-down" => ("m19.5 8.25-7.5 7.5-7.5-7.5", false),
        "chevron-up" => ("m4.5 15.75 7.5-7.5 7.5 7.5", false),
        "chevron-right" => ("m8.25 4.5 7.5 7.5-7.5 7.5", false),
        "chevron-left" => ("M15.75 19.5 8.25 12l7.5-7.5", false),
        "arrow-path" => (
            "M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182m0-4.991v4.99",
            false,
        ),
        "arrow-down-tray" => (
            "M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 16.5m0 0L7.5 12m4.5 4.5V3",
            false,
        ),
        "arrow-right-on-rectangle" => (
            "M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15M12 9l-3 3m0 0 3 3m-3-3h12.75",
            false,
        ),
        "arrow-down-on-square-stack" => (
            "M7.5 7.5h-.75A2.25 2.25 0 0 0 4.5 9.75v7.5a2.25 2.25 0 0 0 2.25 2.25h7.5a2.25 2.25 0 0 0 2.25-2.25v-7.5a2.25 2.25 0 0 0-2.25-2.25h-.75m0-3-3-3m0 0-3 3m3-3v11.25m6-2.25h.75a2.25 2.25 0 0 1 2.25 2.25v7.5a2.25 2.25 0 0 1-2.25 2.25h-7.5a2.25 2.25 0 0 1-2.25-2.25v-.75",
            false,
        ),
        "calendar" => (
            "M6.75 3v2.25M17.25 3v2.25M3 18.75V7.5a2.25 2.25 0 0 1 2.25-2.25h13.5A2.25 2.25 0 0 1 21 7.5v11.25m-18 0A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75m-18 0v-7.5A2.25 2.25 0 0 1 5.25 9h13.5A2.25 2.25 0 0 1 21 11.25v7.5",
            false,
        ),
        "clock" => (
            "M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
            false,
        ),
        "folder" => (
            "M2.25 12.75V12A2.25 2.25 0 0 1 4.5 9.75h15A2.25 2.25 0 0 1 21.75 12v.75m-8.69-6.44-2.12-2.12a1.5 1.5 0 0 0-1.061-.44H4.5A2.25 2.25 0 0 0 2.25 6v12a2.25 2.25 0 0 0 2.25 2.25h15A2.25 2.25 0 0 0 21.75 18V9a2.25 2.25 0 0 0-2.25-2.25h-5.379a1.5 1.5 0 0 1-1.06-.44Z",
            false,
        ),
        "cog-6-tooth" => (
            "M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.28Z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
            false,
        ),
        "users" => (
            "M15 19.128a9.38 9.38 0 0 0 2.625.372 9.337 9.337 0 0 0 4.121-.952 4.125 4.125 0 0 0-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 0 1 8.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0 1 11.964-3.07M12 6.375a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0Zm8.25 2.25a2.625 2.625 0 1 1-5.25 0 2.625 2.625 0 0 1 5.25 0Z",
            false,
        ),
        "magnifying-glass" => (
            "m21 21-5.197-5.197m0 0A7.5 7.5 0 1 0 5.196 5.196a7.5 7.5 0 0 0 10.607 10.607Z",
            false,
        ),
        "sparkles" => (
            "M9.813 15.904 9 18.75l-.813-2.846a4.5 4.5 0 0 0-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 0 0 3.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 0 0 3.09 3.09L15.75 12l-2.847.813a4.5 4.5 0 0 0-3.09 3.09ZM18.259 8.715 18 9.75l-.259-1.035a3.375 3.375 0 0 0-2.456-2.456L14.25 6l1.035-.259a3.375 3.375 0 0 0 2.456-2.456L18 2.25l.259 1.035a3.375 3.375 0 0 0 2.456 2.456L21.75 6l-1.035.259a3.375 3.375 0 0 0-2.456 2.456ZM16.894 20.567 16.5 21.75l-.394-1.183a2.25 2.25 0 0 0-1.423-1.423L13.5 18.75l1.183-.394a2.25 2.25 0 0 0 1.423-1.423l.394-1.183.394 1.183a2.25 2.25 0 0 0 1.423 1.423l1.183.394-1.183.394a2.25 2.25 0 0 0-1.423 1.423Z",
            false,
        ),
        "star" => (
            "M11.48 3.499a.562.562 0 0 1 1.04 0l2.125 5.111a.563.563 0 0 0 .475.345l5.518.442c.499.04.701.663.321.988l-4.204 3.602a.563.563 0 0 0-.182.557l1.285 5.385a.562.562 0 0 1-.84.61l-4.725-2.885a.562.562 0 0 0-.586 0L6.982 20.54a.562.562 0 0 1-.84-.61l1.285-5.386a.562.562 0 0 0-.182-.557l-4.204-3.602a.562.562 0 0 1 .321-.988l5.518-.442a.563.563 0 0 0 .475-.345L11.48 3.5Z",
            false,
        ),
        "star-solid" => (
            "M11.48 3.499a.562.562 0 0 1 1.04 0l2.125 5.111a.563.563 0 0 0 .475.345l5.518.442c.499.04.701.663.321.988l-4.204 3.602a.563.563 0 0 0-.182.557l1.285 5.385a.562.562 0 0 1-.84.61l-4.725-2.885a.562.562 0 0 0-.586 0L6.982 20.54a.562.562 0 0 1-.84-.61l1.285-5.386a.562.562 0 0 0-.182-.557l-4.204-3.602a.562.562 0 0 1 .321-.988l5.518-.442a.563.563 0 0 0 .475-.345L11.48 3.5Z",
            true,
        ),
        "exclamation-circle" => (
            "M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z",
            false,
        ),
        "exclamation-triangle" => (
            "M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126ZM12 15.75h.007v.008H12v-.008Z",
            false,
        ),
        "information-circle" => (
            "m11.25 11.25.041-.02a.75.75 0 0 1 1.063.852l-.708 2.836a.75.75 0 0 0 1.063.853l.041-.021M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9-3.75h.008v.008H12V8.25Z",
            false,
        ),
        "user" => (
            "M15.75 6a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0ZM4.501 20.118a7.5 7.5 0 0 1 14.998 0A17.933 17.933 0 0 1 12 21.75c-2.676 0-5.216-.584-7.499-1.632Z",
            false,
        ),
        "film" => (
            "M3 4.5h18M3 9h18M3 13.5h18M3 18h18M7.5 4.5v15m9-15v15M4.5 4.5h15a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 18V6a1.5 1.5 0 0 1 1.5-1.5Z",
            false,
        ),
        "tv" => (
            "M6 20.25h12m-7.5-3v3m3-3v3m-10.125-3h17.25c.621 0 1.125-.504 1.125-1.125V4.875c0-.621-.504-1.125-1.125-1.125H3.375c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125Z",
            false,
        ),
        "musical-note" => (
            "M9 9l10.5-3m0 6.553v3.75a2.25 2.25 0 0 1-1.632 2.163l-1.32.377a1.803 1.803 0 1 1-.99-3.467l2.31-.66a2.25 2.25 0 0 0 1.632-2.163Zm0 0V2.25L9 5.25v10.303m0 0v3.75a2.25 2.25 0 0 1-1.632 2.163l-1.32.377a1.803 1.803 0 0 1-.99-3.467l2.31-.66A2.25 2.25 0 0 0 9 15.553Z",
            false,
        ),
        "book-open" => (
            "M12 6.042A8.967 8.967 0 0 0 6 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 0 1 6 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 0 1 6-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0 0 18 18a8.967 8.967 0 0 0-6 2.292m0-14.25v14.25",
            false,
        ),
        "signal" => (
            "M9.348 14.652a3.75 3.75 0 0 1 0-5.304m5.304 0a3.75 3.75 0 0 1 0 5.304m-7.425 2.121a6.75 6.75 0 0 1 0-9.546m9.546 0a6.75 6.75 0 0 1 0 9.546M5.106 18.894c-3.808-3.807-3.808-9.98 0-13.788m13.788 0c3.808 3.807 3.808 9.98 0 13.788M12 12h.008v.008H12V12Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z",
            false,
        ),
        "list-bullet" => (
            "M8.25 6.75h12M8.25 12h12m-12 5.25h12M3.75 6.75h.007v.008H3.75V6.75Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0ZM3.75 12h.007v.008H3.75V12Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Zm-.375 5.25h.007v.008H3.75v-.008Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z",
            false,
        ),
        "queue-list" => (
            "M3.75 12h16.5m-16.5 3.75h16.5M3.75 19.5h16.5M5.625 4.5h12.75a1.875 1.875 0 0 1 0 3.75H5.625a1.875 1.875 0 0 1 0-3.75Z",
            false,
        ),
        "photo" => (
            "m2.25 15.75 5.159-5.159a2.25 2.25 0 0 1 3.182 0l5.159 5.159m-1.5-1.5 1.409-1.409a2.25 2.25 0 0 1 3.182 0l2.909 2.909m-18 3.75h16.5a1.5 1.5 0 0 0 1.5-1.5V6a1.5 1.5 0 0 0-1.5-1.5H3.75A1.5 1.5 0 0 0 2.25 6v12a1.5 1.5 0 0 0 1.5 1.5Zm10.5-11.25h.008v.008h-.008V8.25Zm.375 0a.375.375 0 1 1-.75 0 .375.375 0 0 1 .75 0Z",
            false,
        ),
        "inbox-stack" => (
            "M7.875 14.25h8.25M2.25 13.5l1.594-5.578a2.25 2.25 0 0 1 2.163-1.626h12.014a2.25 2.25 0 0 1 2.163 1.626L21.75 13.5m-19.5 0v6.75a2.25 2.25 0 0 0 2.25 2.25h15a2.25 2.25 0 0 0 2.25-2.25V13.5m-19.5 0h6.018c.319 0 .615.135.827.359.404.422.978.641 1.562.641h4.186c.584 0 1.158-.219 1.562-.641a1.125 1.125 0 0 1 .827-.359H21.75",
            false,
        ),
        "no-symbol" => (
            "M18.364 18.364A9 9 0 0 0 5.636 5.636m12.728 12.728A9 9 0 0 1 5.636 5.636m12.728 12.728L5.636 5.636",
            false,
        ),
        "chat-bubble-left-right" => (
            "M20.25 8.511c.884.284 1.5 1.128 1.5 2.097v4.286c0 1.136-.847 2.1-1.98 2.193-.34.027-.68.052-1.02.072v3.091l-3-3c-1.354 0-2.694-.055-4.02-.163a2.115 2.115 0 0 1-.825-.242m9.345-8.334a2.126 2.126 0 0 0-.476-.095 48.64 48.64 0 0 0-8.048 0c-1.131.094-1.976 1.057-1.976 2.192v4.286c0 .837.46 1.58 1.155 1.951m9.345-8.334V6.637c0-1.621-1.152-3.026-2.76-3.235A48.455 48.455 0 0 0 11.25 3c-2.115 0-4.198.137-6.24.402-1.608.209-2.76 1.614-2.76 3.235v6.226c0 1.621 1.152 3.026 2.76 3.235.577.075 1.157.14 1.74.194V21l4.155-4.155",
            false,
        ),
        "play-solid" => (
            "M4.5 5.653c0-1.426 1.529-2.33 2.779-1.643l11.54 6.347c1.295.712 1.295 2.573 0 3.286L7.28 19.99c-1.25.687-2.779-.217-2.779-1.643V5.653Z",
            true,
        ),
        "play-circle-solid" => (
            "M2.25 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75S2.25 17.385 2.25 12Zm9.5-3.75 4.5 3.75-4.5 3.75v-7.5Z",
            true,
        ),
        "sun" => (
            "M12 3v2.25m6.364.386-1.591 1.591M21 12h-2.25m-.386 6.364-1.591-1.591M12 18.75V21m-4.773-4.227-1.591 1.591M5.25 12H3m4.227-4.773L5.636 5.636M15.75 12a3.75 3.75 0 1 1-7.5 0 3.75 3.75 0 0 1 7.5 0Z",
            false,
        ),
        "moon" => (
            "M21.752 15.002A9.72 9.72 0 0 1 18 15.75c-5.385 0-9.75-4.365-9.75-9.75 0-1.33.266-2.597.748-3.752A9.753 9.753 0 0 0 3 11.25C3 16.635 7.365 21 12.75 21a9.753 9.753 0 0 0 9.002-5.998Z",
            false,
        ),
        "computer-desktop" => (
            "M9 17.25v1.007a3 3 0 0 1-.879 2.122L7.5 21h9l-.621-.621A3 3 0 0 1 15 18.257V17.25m6-12V15a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 15V5.25m18 0A2.25 2.25 0 0 0 18.75 3H5.25A2.25 2.25 0 0 0 3 5.25m18 0V12a2.25 2.25 0 0 1-2.25 2.25H5.25A2.25 2.25 0 0 1 3 12V5.25",
            false,
        ),
        "check" => ("m4.5 12.75 6 6 9-13.5", false),
        "pencil-square" => (
            "m16.862 4.487 1.687-1.688a1.875 1.875 0 1 1 2.652 2.652L10.582 16.07a4.5 4.5 0 0 1-1.897 1.13L6 18l.8-2.685a4.5 4.5 0 0 1 1.13-1.897l8.932-8.931Zm0 0L19.5 7.125M18 14v4.75A2.25 2.25 0 0 1 15.75 21H5.25A2.25 2.25 0 0 1 3 18.75V8.25A2.25 2.25 0 0 1 5.25 6H10",
            false,
        ),
        "eye-slash" => (
            "M3.98 8.223A10.477 10.477 0 0 0 1.934 12C3.226 16.338 7.244 19.5 12 19.5c.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88",
            false,
        ),
        "eye" => (
            "M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178Z M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
            false,
        ),
        "plus-circle" => (
            "M12 9v6m3-3H9m12 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
            false,
        ),
        "check-circle" => (
            "M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
            false,
        ),
        "x-circle" => (
            "m9.75 9.75 4.5 4.5m0-4.5-4.5 4.5M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z",
            false,
        ),
        "pause" => (
            "M15.75 5.25v13.5m-7.5-13.5v13.5",
            false,
        ),
        "play" => (
            "M5.25 5.653c0-.856.917-1.398 1.667-.986l11.54 6.347a1.125 1.125 0 0 1 0 1.972l-11.54 6.347a1.125 1.125 0 0 1-1.667-.986V5.653Z",
            false,
        ),
        "funnel" => (
            "M12 3c-2.755 0-5.455.232-8.083.678.533.892.892 1.892 1.04 2.96.114.81.515 1.546 1.157 2.046l1.84 1.432a4.502 4.502 0 0 1 1.708 3.547V19.5l3-2.25v-3.587a4.503 4.503 0 0 1 1.707-3.547l1.84-1.432c.643-.5 1.044-1.236 1.158-2.046.148-1.068.507-2.068 1.04-2.96A48.27 48.27 0 0 0 12 3Z",
            false,
        ),
        _ => {
            tracing::warn!(name = %props.name, "unknown icon");
            ("", false)
        }
    };

    let svg_fill = if fill { "currentColor" } else { "none" };

    rsx! {
        svg {
            xmlns: "http://www.w3.org/2000/svg",
            fill: "{svg_fill}",
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
        div { role: "alert", class: "{props.kind.alert_class()} w-80 sm:w-96 max-w-80 sm:max-w-96",
            Icon { name: props.kind.icon().to_string(), class: "size-5 shrink-0".to_string() }
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

/// Renders a vertical stack of flash messages, positioned top-end.
/// Mirrors Phoenix's `<.flash_group>` in `Layouts`, including the
/// `toast toast-top toast-end` positioning.
#[component]
pub fn FlashGroup(props: FlashGroupProps) -> Element {
    if props.flashes.is_empty() {
        return rsx! {};
    }
    rsx! {
        div {
            id: "flash-group",
            class: "toast toast-top toast-end z-50",
            "aria-live": "polite",
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
        assert_eq!(ButtonVariant::Warning.class(), "btn-warning");
        assert_eq!(ButtonVariant::Success.class(), "btn-success");
        assert_eq!(ButtonVariant::Info.class(), "btn-info");
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

    #[test]
    fn badge_variant_class_maps_to_daisyui() {
        assert_eq!(BadgeVariant::Neutral.class(), "");
        assert_eq!(BadgeVariant::Primary.class(), "badge-primary");
        assert_eq!(BadgeVariant::Outline.class(), "badge-outline");
    }

    #[test]
    fn modal_size_class_maps_to_daisyui() {
        assert_eq!(ModalSize::Sm.class(), "max-w-md");
        assert_eq!(ModalSize::Md.class(), "max-w-lg");
        assert_eq!(ModalSize::Lg.class(), "max-w-2xl");
        assert_eq!(ModalSize::Xl.class(), "max-w-4xl");
    }

    #[test]
    fn progress_variant_class_maps_to_daisyui() {
        assert_eq!(ProgressVariant::Neutral.class(), "");
        assert_eq!(ProgressVariant::Primary.class(), "progress-primary");
        assert_eq!(ProgressVariant::Success.class(), "progress-success");
    }
}
