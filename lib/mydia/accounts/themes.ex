defmodule Mydia.Accounts.Themes do
  @moduledoc """
  The UI themes a user can pick, and how a stored choice resolves.

  This list is the source of truth for the picker and for preference
  validation. Every id here needs a matching `[data-theme="<id>"]` rule in
  the CSS (`assets/css/mydiaTheme.ts`, the daisyUI `themes:` list and the
  Catppuccin plugins in `assets/css/app.css`);
  `MydiaWeb.ThemesCssParityTest` fails when the two drift apart.

  Removing a theme is safe: a stored id that is no longer listed reads as
  the default for its slot.
  """
  alias Mydia.Accounts.Themes.{Selection, Theme}

  @modes ~w(system light dark)

  @themes [
    %Theme{id: "mydia-light", label: "Mydia Light", scheme: :light, base: "#f8fafc"},
    %Theme{id: "nord", label: "Nord", scheme: :light, base: "#eceff4"},
    %Theme{id: "emerald", label: "Emerald", scheme: :light, base: "#ffffff"},
    %Theme{id: "mydia-dark", label: "Mydia Dark", scheme: :dark, base: "#0f172a"},
    %Theme{id: "mydia-oled", label: "Mydia OLED", scheme: :dark, base: "#000000"},
    %Theme{id: "dim", label: "Dim", scheme: :dark, base: "#2a303c"},
    %Theme{id: "dracula", label: "Dracula", scheme: :dark, base: "#282a36"},
    %Theme{id: "night", label: "Night", scheme: :dark, base: "#0f172a"},
    %Theme{id: "sunset", label: "Sunset", scheme: :dark, base: "#121c22"},
    %Theme{id: "frappe", label: "Catppuccin Frappé", scheme: :dark, base: "#303446"},
    %Theme{id: "macchiato", label: "Catppuccin Macchiato", scheme: :dark, base: "#24273a"},
    %Theme{id: "mocha", label: "Catppuccin Mocha", scheme: :dark, base: "#1e1e2e"}
  ]

  @doc "The three modes: follow the OS, always light, always dark."
  def modes, do: @modes

  @doc "Every theme, light first, in picker order."
  def all, do: @themes

  def light, do: Enum.filter(@themes, &(&1.scheme == :light))
  def dark, do: Enum.filter(@themes, &(&1.scheme == :dark))

  @doc "The theme with this id, or nil."
  def get(id) when is_binary(id), do: Enum.find(@themes, &(&1.id == id))
  def get(_id), do: nil

  @doc "The theme with this id if it belongs to `scheme`, else nil."
  def get(id, scheme) do
    case get(id) do
      %Theme{scheme: ^scheme} = theme -> theme
      _ -> nil
    end
  end

  def valid_id?(id, scheme), do: get(id, scheme) != nil

  def default(:light), do: get("mydia-light")
  def default(:dark), do: get("mydia-dark")

  def default_selection, do: selection(nil, nil, nil)

  @doc """
  Resolves stored values into a `Selection`. Each field falls back on its
  own, so one bad value never discards the others.
  """
  def selection(mode, light_id, dark_id) do
    %Selection{
      mode: if(mode in @modes, do: mode, else: "system"),
      light: get(light_id, :light) || default(:light),
      dark: get(dark_id, :dark) || default(:dark)
    }
  end

  @doc "The theme on screen for a fixed mode; nil in system mode, where only the browser knows."
  def active(%Selection{mode: "light", light: theme}), do: theme
  def active(%Selection{mode: "dark", dark: theme}), do: theme
  def active(%Selection{}), do: nil

  @doc "The `theme_changed` push_event payload read by `assets/js/theme.mjs`."
  def to_client(%Selection{} = s) do
    %{
      mode: s.mode,
      light_theme: s.light.id,
      dark_theme: s.dark.id,
      light_base: s.light.base,
      dark_base: s.dark.base
    }
  end
end
