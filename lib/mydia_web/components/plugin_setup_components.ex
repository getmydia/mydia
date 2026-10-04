defmodule MydiaWeb.PluginSetupComponents do
  @moduledoc """
  Renderers shared by the plugin settings modal and the plugin setup modal.

  Plugin manifests (`settings_schema`) and setup form screens both describe
  fields as `%{"key", "label", "hint", "type", "options"}`; `settings_field/1` renders
  one with core components. Secrets render as password inputs and are never
  echoed back.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents

  attr :field, :map, required: true
  attr :form, :any, required: true
  attr :disabled, :boolean, default: false

  def settings_field(%{field: %{"type" => "enum"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      disabled={@disabled}
      type="select"
      label={@field["label"] || @field["key"]}
      options={@field["options"] || []}
      hint={@field["hint"]}
    />
    """
  end

  def settings_field(%{field: %{"type" => "secret"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      disabled={@disabled}
      type="password"
      autocomplete="off"
      label={@field["label"] || @field["key"]}
      placeholder="••••••••"
      hint={@field["hint"]}
    />
    """
  end

  def settings_field(%{field: %{"type" => "url"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      disabled={@disabled}
      type="url"
      label={@field["label"] || @field["key"]}
      hint={url_hint(@field)}
    />
    """
  end

  def settings_field(%{field: %{"type" => "text"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      disabled={@disabled}
      type="textarea"
      label={@field["label"] || @field["key"]}
      hint={@field["hint"]}
    />
    """
  end

  def settings_field(assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      disabled={@disabled}
      type="text"
      label={@field["label"] || @field["key"]}
      hint={@field["hint"]}
    />
    """
  end

  @private_host_note "This address may be on your local network. Saving it lets the plugin reach that one host."

  # The manifest's own hint, followed by the private-network note when the field
  # may point at a local address.
  defp url_hint(field) do
    [field["hint"], field["allow_private"] && @private_host_note]
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  @doc """
  Converts a setup screen field (WIT `setup-field`, decoded with atom keys) into
  the string-keyed shape `settings_field/1` renders.
  """
  @spec setup_field_to_settings_field(map()) :: map()
  def setup_field_to_settings_field(field) do
    %{
      "key" => field.key,
      "label" => field.label,
      "type" => field.field_type,
      "options" => field.options,
      "required" => field.required
    }
  end
end
