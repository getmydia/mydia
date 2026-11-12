defmodule MydiaWeb.AdminDownloadClientsLive.BuiltInFieldComponents do
  @moduledoc """
  Field rows for the built-in client's settings modal
  (`MydiaWeb.AdminDownloadClientsLive.BuiltInFormComponents`). Each row shows
  where its value comes from. An environment-sourced field is disabled, so the
  browser leaves it out of the submit and `BuiltIn.Settings` treats it as
  unchanged.
  """
  use MydiaWeb, :html

  alias Mydia.Config.Schema.BuiltInTorrent

  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sources, :map, required: true
  attr :for, :string, default: nil
  slot :inner_block, required: true
  slot :hint

  def field_row(assigns) do
    assigns =
      assigns
      |> assign(:source, source(assigns.sources, assigns.field))
      |> assign(:env_var, env_var(assigns.field))

    ~H"""
    <div class="space-y-1">
      <div class="flex flex-wrap items-center gap-2">
        <label for={@for} class="text-sm font-medium text-base-content/80">{@label}</label>
        <span
          id={"built-in-source-#{@field}"}
          title={
            if(@source == :env,
              do:
                gettext("Set by %{variable}; change it in the container environment.",
                  variable: @env_var
                )
            )
          }
        >
          <.config_source_badge source={@source} size="xs" />
        </span>
        <span :if={@source == :env} class="text-xs text-base-content/60 font-mono break-all">
          {@env_var}
        </span>
      </div>
      {render_slot(@inner_block)}
      <p :if={@hint != []} class="text-xs text-base-content/60">{render_slot(@hint)}</p>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sources, :map, required: true
  attr :type, :string, default: "text"
  attr :rest, :global, include: ~w(placeholder autocomplete)

  def text_field(assigns) do
    assigns = assign(assigns, :id, field_id(assigns.field))

    ~H"""
    <.field_row field={@field} label={@label} sources={@sources} for={@id}>
      <.input
        field={@form[@field]}
        id={@id}
        type={@type}
        disabled={locked?(@sources, @field)}
        {@rest}
      />
    </.field_row>
    """
  end

  @doc """
  A segmented choice backed by a hidden input, so the value travels with the
  form on submit. A locked field renders its value as text and sends nothing.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :locked?, :boolean, required: true
  attr :options, :list, required: true

  def choice(assigns) do
    assigns = assign(assigns, :value, to_string(assigns.form[assigns.field].value))

    ~H"""
    <%= if @locked? do %>
      <p class="text-sm">{choice_label(@options, @value)}</p>
    <% else %>
      <.segmented_control
        id={"built-in-#{@field}"}
        value={@value}
        event="validate_built_in"
        param={Atom.to_string(@field)}
        label={@label}
      >
        <:option
          :for={{value, label} <- @options}
          id={"built-in-#{@field}-#{value}"}
          value={value}
          label={label}
        />
      </.segmented_control>
      <input type="hidden" name={@form[@field].name} value={@value} />
    <% end %>
    """
  end

  @doc """
  A secret input that is never bound to a value. A saved secret shows "Saved"
  and a Replace button; a typed one stays in the browser
  (`phx-update="ignore"`) until the form is submitted.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :sources, :map, required: true
  attr :saved_secrets, :map, required: true
  attr :replacing, :list, required: true
  attr :typed_secrets, :list, required: true

  def secret_field(assigns) do
    field = assigns.field
    saved? = Map.get(assigns.saved_secrets, field, false)

    assigns =
      assigns
      |> assign(:id, field_id(field))
      |> assign(:locked?, locked?(assigns.sources, field))
      |> assign(:show_saved?, saved? and field not in assigns.replacing)
      |> assign(:errors, secret_errors(assigns.form, field, assigns.typed_secrets))

    ~H"""
    <.field_row field={@field} label={@label} sources={@sources} for={@id}>
      <%= cond do %>
        <% @locked? -> %>
          <p class="text-sm text-base-content/70">{gettext("Set in the environment")}</p>
        <% @show_saved? -> %>
          <div class="flex items-center gap-2">
            <span class="badge badge-success badge-soft gap-1">
              <.icon name="hero-lock-closed" class="size-3" /> {gettext("Saved")}
            </span>
            <button
              id={"built-in-secret-replace-#{@field}"}
              type="button"
              class="btn btn-sm border-base-content/20"
              phx-click="replace_built_in_secret"
              phx-value-field={@field}
            >
              {gettext("Replace")}
            </button>
          </div>
        <% true -> %>
          <%!-- Never bound to a value: the typed secret stays in the browser across re-renders. --%>
          <div id={"#{@id}-wrapper"} phx-update="ignore">
            <input
              type="password"
              id={@id}
              name={@form[@field].name}
              value=""
              autocomplete="new-password"
              class="w-full input bg-base-200/50 transition-colors duration-150 focus:bg-base-100"
            />
          </div>
          <p :for={msg <- @errors} class="mt-1.5 flex gap-2 items-center text-sm text-error">
            <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
          </p>
      <% end %>
    </.field_row>
    """
  end

  @doc "Whether the field's value comes from the environment, which makes it read-only."
  def locked?(sources, field), do: source(sources, field) == :env

  defp field_id(field), do: "built-in-field-#{field}"

  defp source(sources, field), do: Map.get(sources, field, :default)

  defp env_var(field), do: Keyword.fetch!(BuiltInTorrent.env_vars(), field)

  defp choice_label(options, value) do
    Enum.find_value(options, value, fn {v, label} -> if v == value, do: label end)
  end

  # Secret params are stripped from the changeset, so `used_input?/1` never
  # sees them. Show the error only once the form has been edited and the user
  # has not typed a value the server cannot see on this event.
  defp secret_errors(form, field, typed_secrets) do
    if form.params != %{} and field not in typed_secrets do
      for {^field, error} <- form.errors, do: translate_error(error)
    else
      []
    end
  end
end
