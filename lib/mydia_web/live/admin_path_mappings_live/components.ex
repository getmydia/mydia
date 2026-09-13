defmodule MydiaWeb.AdminPathMappingsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings

  @doc """
  Renders the Path Mappings tab content.
  """
  attr :path_mappings, :list, required: true

  def path_mappings_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <p class="text-sm text-base-content/70">
        Translate paths reported by download clients into paths Mydia can see.
        The longest matching prefix wins.
      </p>

      <%= if @path_mappings == [] do %>
        <div id="path-mappings-empty" class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No path mappings configured yet. Add one above, or set the
            <code class="font-mono">PATH_MAPPING_N_REMOTE</code>
            / <code class="font-mono">PATH_MAPPING_N_LOCAL</code>
            environment variables.
          </span>
        </div>
      <% else %>
        <div id="path-mappings-list" class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for mapping <- @path_mappings do %>
            <% is_runtime = Settings.runtime_config?(mapping) %>
            <.path_mapping_row mapping={mapping} is_runtime={is_runtime} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc "The page header's Add mapping button."
  def header_actions(assigns) do
    ~H"""
    <button class="btn btn-sm btn-primary" phx-click="new_path_mapping">
      <.icon name="hero-plus" class="w-4 h-4" /> Add mapping
    </button>
    """
  end

  attr :mapping, :map, required: true
  attr :is_runtime, :boolean, required: true

  defp path_mapping_row(assigns) do
    ~H"""
    <div id={"mapping-#{@mapping.id}"} class="p-3 sm:p-4">
      <div class="flex flex-col sm:flex-row sm:items-center gap-3">
        <%!-- Mapping Info --%>
        <div class="flex-1 min-w-0">
          <div class="font-mono text-sm break-all flex items-center gap-2 flex-wrap">
            <span>{@mapping.remote_prefix}</span>
            <.icon name="hero-arrow-right" class="w-4 h-4 opacity-50 shrink-0" />
            <span>{@mapping.local_prefix}</span>
          </div>
        </div>

        <%!-- Badges + Actions --%>
        <div class="flex flex-wrap items-center gap-2">
          <%= if @is_runtime do %>
            <span
              class="badge badge-primary badge-xs tooltip"
              data-tip="Configured via environment variables (read-only)"
            >
              <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
            </span>
          <% end %>

          <div class="join ml-auto sm:ml-2">
            <%= if @is_runtime do %>
              <div class="tooltip" data-tip="Cannot edit environment-configured mappings">
                <button
                  class="btn btn-sm btn-ghost join-item"
                  phx-click="edit_path_mapping"
                  phx-value-id={@mapping.id}
                  disabled={@is_runtime}
                >
                  <.icon name="hero-pencil" class="w-4 h-4 opacity-30" />
                </button>
              </div>
              <div class="tooltip" data-tip="Cannot delete environment-configured mappings">
                <button
                  class="btn btn-sm btn-ghost join-item"
                  phx-click="delete_path_mapping"
                  phx-value-id={@mapping.id}
                  disabled={@is_runtime}
                >
                  <.icon name="hero-trash" class="w-4 h-4 opacity-30" />
                </button>
              </div>
            <% else %>
              <button
                class="btn btn-sm btn-ghost join-item"
                phx-click="edit_path_mapping"
                phx-value-id={@mapping.id}
                disabled={@is_runtime}
                title="Edit"
              >
                <.icon name="hero-pencil" class="w-4 h-4" />
              </button>
              <button
                class="btn btn-sm btn-ghost join-item text-error"
                phx-click="delete_path_mapping"
                phx-value-id={@mapping.id}
                disabled={@is_runtime}
                data-confirm="Are you sure you want to delete this path mapping?"
                title="Delete"
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

  @doc """
  Renders the Path Mapping modal.
  """
  attr :form, :any, required: true
  attr :mode, :atom, required: true
  attr :remote_suggestions, :list, default: []
  attr :local_suggestions, :list, default: []

  def path_mapping_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-xl">
        <.form
          for={@form}
          id="path-mapping-form"
          phx-change="validate_path_mapping"
          phx-submit="save_path_mapping"
        >
          <%!-- Header --%>
          <div class="flex items-center gap-3 mb-5">
            <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
              <.icon
                name={if(@mode == :new, do: "hero-plus-circle", else: "hero-pencil-square")}
                class="w-5 h-5 text-primary"
              />
            </div>
            <div>
              <h3 class="font-bold text-lg">
                {if @mode == :new, do: "Add Path Mapping", else: "Edit Path Mapping"}
              </h3>
              <p class="text-sm text-base-content/60">
                {if @mode == :new,
                  do: "Configure a new path translation",
                  else: "Update path translation"}
              </p>
            </div>
          </div>

          <div class="space-y-5">
            <div>
              <.input
                field={@form[:remote_prefix]}
                type="text"
                label="Remote prefix"
                placeholder="/downloads/complete"
                list="remote-prefix-suggestions"
                autocomplete="off"
                required
              />
              <datalist id="remote-prefix-suggestions">
                <option :for={path <- @remote_suggestions} value={path}></option>
              </datalist>
              <%= if @remote_suggestions != [] do %>
                <p class="text-xs text-base-content/60 mt-1">
                  Suggestions come from downloads that failed to import because their reported path could not be mapped.
                </p>
              <% end %>
            </div>
            <div>
              <.input
                field={@form[:local_prefix]}
                type="text"
                label="Local prefix"
                placeholder="/data/torrents/complete"
                list="local-prefix-suggestions"
                autocomplete="off"
                required
              />
              <datalist id="local-prefix-suggestions">
                <option :for={path <- @local_suggestions} value={path}></option>
              </datalist>
              <p class="text-xs text-base-content/60 mt-1">
                As you type, Mydia suggests matching directories on its own filesystem.
              </p>
            </div>
          </div>

          <%!-- Modal Actions --%>
          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_modal">Cancel</button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if @mode == :new, do: "Add Mapping", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_modal"></div>
    </div>
    """
  end
end
