defmodule MydiaWeb.PluginSetupComponents do
  @moduledoc """
  Renderers shared by the plugin settings modal and the plugin setup modal.

  Plugin manifests (`settings_schema`) and setup form screens both describe
  fields as `%{"key", "label", "type", "options"}`; `settings_field/1` renders
  one with core components. Secrets render as password inputs and are never
  echoed back.
  """

  use Phoenix.Component

  import MydiaWeb.CoreComponents

  attr :field, :map, required: true
  attr :form, :any, required: true

  def settings_field(%{field: %{"type" => "enum"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="select"
      label={@field["label"] || @field["key"]}
      options={@field["options"] || []}
    />
    """
  end

  def settings_field(%{field: %{"type" => "secret"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="password"
      autocomplete="off"
      label={@field["label"] || @field["key"]}
      placeholder="••••••••"
    />
    """
  end

  def settings_field(%{field: %{"type" => "url"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="url"
      label={@field["label"] || @field["key"]}
      hint={
        if @field["allow_private"],
          do:
            "This address may be on your local network. Saving it lets the plugin reach that one host."
      }
    />
    """
  end

  def settings_field(%{field: %{"type" => "text"}} = assigns) do
    ~H"""
    <.input
      field={@form[@field["key"]]}
      type="textarea"
      label={@field["label"] || @field["key"]}
    />
    """
  end

  def settings_field(assigns) do
    ~H"""
    <.input field={@form[@field["key"]]} type="text" label={@field["label"] || @field["key"]} />
    """
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
