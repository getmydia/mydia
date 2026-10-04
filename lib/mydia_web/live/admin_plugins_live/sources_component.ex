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
  def handle_event("open_add", _params, socket) do
    {:noreply,
     assign(socket, adding?: true, preview: nil, error: nil, form: to_form(%{"url" => ""}))}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply, assign(socket, adding?: false, preview: nil, previewing?: false, error: nil)}
  end

  def handle_event("preview", %{"url" => url}, socket) do
    {:noreply,
     socket
     |> assign(previewing?: true, preview: nil, error: nil, form: to_form(%{"url" => url}))
     |> start_async(:preview, fn -> Index.preview_source(url) end)}
  end

  def handle_event("confirm_add", _params, %{assigns: %{preview: preview}} = socket)
      when not is_nil(preview) do
    attrs = %{url: preview.url, name: preview.name, public_key: preview.public_key}

    case Sources.add_source(attrs) do
      {:ok, _} ->
        {:noreply, socket |> assign(adding?: false, preview: nil) |> load_sources()}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}
    end
  end

  def handle_event("confirm_add", _params, socket), do: {:noreply, socket}

  def handle_event("remove", %{"id" => id}, socket) do
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
    <div id="plugin-sources" class="bg-base-200 rounded-box p-3 sm:p-4 space-y-3">
      <div class="flex items-center justify-between gap-2">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-globe-alt" class="w-5 h-5 opacity-60" /> Plugin sources
        </h2>
        <button
          id="add-source"
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="open_add"
          phx-target={@myself}
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add source
        </button>
      </div>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th>URL</th>
              <th>Key</th>
              <th>Plugins</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@official} id="source-row-official">
              <td class="font-medium">Mydia plugin index</td>
              <td class="text-xs break-all min-w-48">{@official.url}</td>
              <td class="font-mono text-xs">{fingerprint(@official.public_key)}</td>
              <td></td>
              <td><span class="badge badge-sm badge-ghost">Official</span></td>
            </tr>
            <tr :for={source <- @sources} id={"source-row-#{source.id}"}>
              <td class="font-medium break-words">{source.name || source.url}</td>
              <td class="text-xs break-all min-w-48">{source.url}</td>
              <td class="font-mono text-xs">{source.key_id}</td>
              <td>{source.plugin_count}</td>
              <td>
                <div class="flex flex-wrap items-center gap-1">
                  <span
                    :if={source.declared}
                    class="badge badge-sm badge-ghost"
                    title="Set in the environment or config file"
                  >
                    Declared
                  </span>
                  <span :if={not source.enabled} class="badge badge-sm badge-ghost">Disabled</span>
                  <span :if={source.last_error} class="text-error text-xs break-words">
                    {source.last_error}
                  </span>
                  <button
                    :if={not source.declared}
                    id={"remove-source-#{source.id}"}
                    type="button"
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="remove"
                    phx-value-id={source.id}
                    phx-target={@myself}
                    data-confirm="Remove this source? Plugins installed from it keep running but stop receiving updates."
                  >
                    Remove
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@adding?} id="add-source-modal" class="modal modal-open">
        <div class="modal-box max-w-lg">
          <h3 class="text-lg font-bold flex items-center gap-2">
            <.icon name="hero-plus-circle" class="w-5 h-5" /> Add a plugin source
          </h3>

          <.form
            for={@form}
            id="add-source-form"
            phx-submit="preview"
            phx-target={@myself}
            class="mt-4"
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

          <div class="modal-action">
            <button
              id="cancel-source"
              type="button"
              class="btn btn-ghost"
              phx-click="cancel_add"
              phx-target={@myself}
            >
              Cancel
            </button>
            <button
              :if={@preview}
              id="confirm-source"
              type="button"
              class="btn btn-primary"
              phx-click="confirm_add"
              phx-target={@myself}
            >
              Trust and add
            </button>
          </div>
        </div>
        <div class="modal-backdrop bg-black/50" phx-click="cancel_add" phx-target={@myself}></div>
      </div>
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
end
