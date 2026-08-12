defmodule MydiaWeb.AdminPluginsLive.ConnectionsComponents do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Connections section for instance-scoped service endpoint plugins.
  """
  attr :connections, :list, required: true
  attr :descriptor, :map, required: true
  attr :connection_form, :map, default: nil
  attr :connect_session, :map, default: nil

  def connections_section(assigns) do
    guest? = Map.get(assigns.descriptor, "onboarding") == "guest"
    fields = Map.get(assigns.descriptor, "fields")

    assigns =
      assigns
      |> assign(:guest_onboarding?, guest?)
      |> assign(:fields_descriptor?, is_list(fields) and fields != [])

    ~H"""
    <section id="plugin-connections" class="space-y-3">
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-link" class="w-5 h-5 opacity-60" /> Connections
          <span class="badge badge-ghost">{length(@connections)}</span>
        </h2>
        <%= if @guest_onboarding? do %>
          <button
            id="connection-connect"
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="connect:start"
          >
            <.icon name="hero-link" class="w-4 h-4" /> Connect
          </button>
        <% else %>
          <button
            id="connection-add"
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="connection:add"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Add
          </button>
        <% end %>
      </div>

      <%= if @connections == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>No connections configured yet.</span>
        </div>
      <% else %>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for conn <- @connections do %>
            <.connection_row connection={conn} descriptor={@descriptor} />
          <% end %>
        </div>
      <% end %>

      <%= if @connection_form do %>
        <.connection_form_modal form={@connection_form} descriptor={@descriptor} />
      <% end %>

      <%= if @connect_session do %>
        <.connect_flow_modal session={@connect_session} />
      <% end %>
    </section>
    """
  end

  attr :connection, :map, required: true
  attr :descriptor, :map, required: true

  def connection_row(assigns) do
    slug = label_slug(assigns.connection.label)
    read_only? = match?(%{from_config?: true}, assigns.connection)

    assigns =
      assigns
      |> assign(:row_id, "connection-row-#{slug}")
      |> assign(:read_only?, read_only?)
      |> assign(:status_badge_class, status_badge_class(assigns.connection))
      |> assign(:status_message, connection_error_message(assigns.connection))

    ~H"""
    <div id={@row_id} class="p-3 sm:p-4">
      <div class="flex flex-col sm:flex-row sm:items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-semibold flex items-center gap-2 flex-wrap">
            {@connection.label}
            <%= if @read_only? do %>
              <span class="badge badge-primary badge-xs">from config file</span>
            <% end %>
          </div>
          <div class="text-xs opacity-60 mt-1 truncate font-mono">
            {connection_address(@connection)}
          </div>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span class={["badge badge-sm", @status_badge_class]}>
            {status_label(@connection.status)}
            <%= if @connection.status == "error" and @status_message != "" do %>
              {": " <> @status_message}
            <% end %>
          </span>

          <div class="join ml-auto sm:ml-2">
            <button
              type="button"
              class="btn btn-sm btn-ghost join-item"
              phx-click="connection:test"
              phx-value-label={@connection.label}
              title="Test connection"
            >
              <.icon name="hero-signal" class="w-4 h-4" />
            </button>
            <%= if not @read_only? do %>
              <button
                type="button"
                class="btn btn-sm btn-ghost join-item"
                phx-click="connection:edit"
                phx-value-label={@connection.label}
                title="Edit"
              >
                <.icon name="hero-pencil" class="w-4 h-4" />
              </button>
              <button
                id={"connection-remove-#{label_slug(@connection.label)}"}
                type="button"
                class="btn btn-sm btn-ghost join-item text-error"
                phx-click="connection:remove"
                phx-value-label={@connection.label}
                data-confirm="Remove this connection?"
                title="Remove"
              >
                <.icon name="hero-trash" class="w-4 h-4" />
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :map, required: true
  attr :descriptor, :map, required: true

  def connection_form_modal(assigns) do
    fields = Map.get(assigns.descriptor, "fields", [])

    assigns = assign(assigns, :fields, fields)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-4">
          {if @form.mode == :add, do: "Add connection", else: "Edit connection"}
        </h3>

        <.form for={@form.form} id="connection-form" phx-submit="connection:save">
          <div class="space-y-3">
            <.input field={@form.form[:label]} type="text" label="Label" required />

            <%= for field <- @fields do %>
              <.input
                field={@form.form[field["key"]]}
                type={if field["secret"], do: "password", else: "text"}
                label={field["label"]}
                placeholder={
                  if field["secret"], do: "Leave blank to keep the stored value", else: nil
                }
              />
            <% end %>
          </div>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="connection:cancel">
              Cancel
            </button>
            <.button type="submit" class="btn-primary">Save</.button>
          </div>
        </.form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="connection:cancel">close</button>
      </form>
    </div>
    """
  end

  attr :session, :map, required: true

  def connect_flow_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-4">Connect</h3>

        <%= if @session.message do %>
          <p class="text-sm mb-3">{@session.message}</p>
        <% end %>

        <%= if @session.status == :pending do %>
          <div class="space-y-3">
            <%= if @session.code do %>
              <div class="font-mono text-2xl tracking-widest">{@session.code}</div>
            <% end %>
            <%= if @session.verification_url do %>
              <a
                href={@session.verification_url}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-primary text-sm"
              >
                Open verification link
              </a>
            <% end %>
            <div class="flex gap-2">
              <button type="button" class="btn btn-sm btn-primary" phx-click="connect:poll">
                Check status
              </button>
              <button type="button" class="btn btn-sm btn-ghost" phx-click="connect:cancel">
                Cancel
              </button>
            </div>
          </div>
        <% end %>

        <%= if @session.status == :prompt do %>
          <.form
            for={@session.form}
            id="connect-form"
            phx-submit="connect:submit"
            class="space-y-3"
          >
            <%= for field <- @session.fields do %>
              <.input
                field={@session.form[field["key"]]}
                type={if field["secret"], do: "password", else: "text"}
                label={field["label"]}
              />
            <% end %>

            <%= if @session.choices != [] do %>
              <.input
                field={@session.form["choice"]}
                type="select"
                label="Choice"
                options={connect_choice_options(@session.choices)}
              />
            <% end %>

            <div class="modal-action">
              <button type="button" class="btn btn-ghost" phx-click="connect:cancel">
                Cancel
              </button>
              <.button type="submit" class="btn-primary">Continue</.button>
            </div>
          </.form>
        <% end %>

        <%= if @session.status == :done do %>
          <div class="modal-action">
            <button type="button" class="btn btn-primary" phx-click="connect:cancel">
              Done
            </button>
          </div>
        <% end %>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" phx-click="connect:cancel">close</button>
      </form>
    </div>
    """
  end

  @spec label_slug(String.t()) :: String.t()
  def label_slug(label) when is_binary(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "connection"
      slug -> slug
    end
  end

  defp connection_address(%{base_urls: urls}) when is_list(urls) and urls != [] do
    Enum.join(urls, ", ")
  end

  defp connection_address(_), do: "No address"

  defp status_label("connected"), do: "Connected"
  defp status_label("error"), do: "Error"
  defp status_label("disabled"), do: "Disabled"
  defp status_label(other), do: other

  defp status_badge_class(%{status: "error"}), do: "badge-error"
  defp status_badge_class(%{status: "disabled"}), do: "badge-ghost"
  defp status_badge_class(_), do: "badge-neutral"

  defp connection_error_message(%{status: "error", meta: meta}) when is_map(meta) do
    Map.get(meta, "message") || Map.get(meta, "error_message") || ""
  end

  defp connection_error_message(_), do: ""

  defp connect_choice_options(choices) do
    Enum.map(choices, fn choice ->
      label = Map.get(choice, "label") || Map.get(choice, "id") || ""
      value = Map.get(choice, "id") || label
      {label, value}
    end)
  end
end
