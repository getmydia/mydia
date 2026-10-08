defmodule MydiaWeb.AdminPluginsLive.SourcesComponent do
  @moduledoc """
  The Sources card on Admin > System > Plugins: the official index, declared
  sources (read-only) and UI-added ones, plus the add flow that previews a
  catalog, shows the key it is signed with, and pins that key on confirm.
  """
  use MydiaWeb, :live_component

  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Index.Signature
  alias Mydia.Plugins.Sources

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       adding?: false,
       preview: nil,
       previewing?: false,
       error: nil,
       form: to_form(%{"url" => ""})
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> load_sources()}
  end

  @impl true
  def handle_event("open_add_source", _params, socket) do
    {:noreply,
     assign(socket, adding?: true, preview: nil, error: nil, form: to_form(%{"url" => ""}))}
  end

  def handle_event("close_add_source_modal", _params, socket) do
    {:noreply, assign(socket, adding?: false, preview: nil, previewing?: false, error: nil)}
  end

  def handle_event("preview_source", %{"url" => url}, socket) do
    {:noreply,
     socket
     |> assign(previewing?: true, preview: nil, error: nil, form: to_form(%{"url" => url}))
     |> start_async(:preview, fn -> Index.preview_source(url) end)}
  end

  def handle_event("confirm_add_source", _params, %{assigns: %{preview: preview}} = socket)
      when not is_nil(preview) do
    attrs = %{url: preview.url, name: preview.name, public_key: preview.public_key}

    case Sources.add_source(attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(adding?: false, preview: nil) |> load_sources()}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}
    end
  end

  def handle_event("confirm_add_source", _params, socket), do: {:noreply, socket}

  def handle_event("remove_source", %{"id" => id}, socket) do
    with %{} = source <- Sources.get_source(id),
         {:ok, _} <- Sources.remove_source(source) do
      {:noreply, load_sources(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Component-level async: the parent LiveView's own :browse handler never sees these.
  @impl true
  def handle_async(:preview, {:ok, {:ok, preview}}, socket),
    do: {:noreply, assign(socket, preview: preview, previewing?: false)}

  def handle_async(:preview, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, error: Exception.message(error), previewing?: false)}

  def handle_async(:preview, {:exit, reason}, socket),
    do:
      {:noreply, assign(socket, error: "Preview failed: #{inspect(reason)}", previewing?: false)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="plugin-sources">
      <.admin_section title="Plugin sources" icon="hero-globe-alt">
        <div class="flex justify-end">
          <button
            id="add-source"
            type="button"
            class="btn btn-sm btn-primary"
            phx-click="open_add_source"
            phx-target={@myself}
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Add source
          </button>
        </div>

        <.admin_table
          id="plugin-sources-table"
          rows={source_rows(@official, @sources)}
          row_id={& &1.dom_id}
        >
          <:col :let={row} label="Name"><span class="font-medium break-words">{row.name}</span></:col>
          <:col :let={row} label="URL"><span class="text-xs break-all">{row.url}</span></:col>
          <:col :let={row} label="Key"><span class="font-mono text-xs">{row.key}</span></:col>
          <:col :let={row} label="Plugins">{row.plugin_count}</:col>
          <:col :let={row} label="Status">
            <div class="flex flex-wrap items-center gap-1">
              <span :if={row.official?} class="badge badge-sm badge-ghost">Official</span>
              <span
                :if={row.declared?}
                class="badge badge-sm badge-ghost"
                title="Set in the environment or config file"
              >
                Declared
              </span>
              <span :if={row.disabled?} class="badge badge-sm badge-ghost">Disabled</span>
              <span :if={row.last_error} class="text-error text-xs break-words">
                {row.last_error}
              </span>
            </div>
          </:col>
          <:action :let={row}>
            <.row_action
              :if={row.removable?}
              id={"remove-source-#{row.id}"}
              icon="hero-trash"
              title="Remove"
              destructive
              phx-click="remove_source"
              phx-value-id={row.id}
              phx-target={@myself}
              data-confirm="Remove this source? Plugins installed from it keep running but stop receiving updates."
            />
          </:action>
          <:empty>No plugin sources.</:empty>
        </.admin_table>
      </.admin_section>

      <.admin_modal
        :if={@adding?}
        id="add-source-modal"
        icon="hero-plus-circle"
        title="Add a plugin source"
        on_close={JS.push("close_add_source_modal", target: @myself)}
      >
        <.form
          for={@form}
          id="add-source-form"
          phx-submit="preview_source"
          phx-target={@myself}
        >
          <.input
            field={@form[:url]}
            type="url"
            label="Catalog URL"
            placeholder="https://example.com/index.json"
          />
          <button type="submit" class="btn btn-sm btn-outline" disabled={@previewing?}>
            <span :if={@previewing?} class="loading loading-spinner loading-xs"></span> Check source
          </button>
        </.form>

        <div :if={@error} id="source-error" class="alert alert-error mt-4 text-sm">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
          <span class="break-words min-w-0">{@error}</span>
        </div>

        <div :if={@preview} id="source-preview" class="mt-4 space-y-3">
          <dl class="text-sm space-y-1">
            <div>
              <dt class="text-base-content/60 text-xs">Name</dt>
              <dd class="font-medium break-words">{@preview.name}</dd>
            </div>
            <div>
              <dt class="text-base-content/60 text-xs">URL</dt>
              <dd class="break-all">{@preview.url}</dd>
            </div>
            <div>
              <dt class="text-base-content/60 text-xs">Signing key</dt>
              <dd class="font-mono">{@preview.fingerprint}</dd>
            </div>
            <div>
              <dt class="text-base-content/60 text-xs">Plugins listed</dt>
              <dd>{@preview.plugin_count}</dd>
            </div>
          </dl>
          <div class="alert alert-warning text-sm">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
            <span>
              Adding this source trusts whoever holds the signing key {@preview.fingerprint}. Mydia
              has not reviewed its plugins. Compare the fingerprint with the one the publisher
              gives you before you continue.
            </span>
          </div>
        </div>

        <:actions>
          <button
            id="cancel-source"
            type="button"
            class="btn btn-ghost"
            phx-click="close_add_source_modal"
            phx-target={@myself}
          >
            Cancel
          </button>
          <button
            :if={@preview}
            id="confirm-source"
            type="button"
            class="btn btn-primary"
            phx-click="confirm_add_source"
            phx-target={@myself}
          >
            Trust and add
          </button>
        </:actions>
      </.admin_modal>
    </div>
    """
  end

  defp load_sources(socket) do
    assign(socket, official: Index.official_source(), sources: Sources.list_sources())
  end

  defp changeset_message(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp fingerprint(key), do: Signature.fingerprint(key)

  defp source_rows(official, sources) do
    official_rows =
      if official do
        [
          %{
            id: nil,
            dom_id: "source-row-official",
            name: "Mydia plugin index",
            url: official.url,
            key: fingerprint(official.public_key),
            plugin_count: nil,
            official?: true,
            declared?: false,
            disabled?: false,
            last_error: nil,
            removable?: false
          }
        ]
      else
        []
      end

    official_rows ++
      Enum.map(sources, fn source ->
        %{
          id: source.id,
          dom_id: "source-row-#{source.id}",
          name: source.name || source.url,
          url: source.url,
          key: source.key_id,
          plugin_count: source.plugin_count,
          official?: false,
          declared?: source.declared,
          disabled?: not source.enabled,
          last_error: source.last_error,
          removable?: not source.declared
        }
      end)
  end
end
