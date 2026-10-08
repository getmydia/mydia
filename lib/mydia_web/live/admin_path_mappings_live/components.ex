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

      <.admin_list id="path-mappings" items={@path_mappings}>
        <:row :let={mapping}>
          <.path_mapping_row mapping={mapping} runtime?={Settings.runtime_config?(mapping)} />
        </:row>
        <:empty>
          No path mappings configured yet. Add one above, or set the
          <code class="font-mono">PATH_MAPPING_N_REMOTE</code>
          / <code class="font-mono">PATH_MAPPING_N_LOCAL</code>
          environment variables.
        </:empty>
      </.admin_list>
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
  attr :runtime?, :boolean, required: true

  defp path_mapping_row(assigns) do
    ~H"""
    <.admin_row id={"path-mapping-#{@mapping.id}"}>
      <:title>
        <%!-- Long paths wrap on purpose; do not truncate them. --%>
        <span class="font-mono text-sm break-all inline-flex items-center gap-2 flex-wrap">
          <span>{@mapping.remote_prefix}</span>
          <.icon name="hero-arrow-right" class="w-4 h-4 opacity-50 shrink-0" />
          <span>{@mapping.local_prefix}</span>
        </span>
        <.env_lock_badge :if={@runtime?} />
      </:title>
      <:actions>
        <.row_actions>
          <.row_action
            id={"edit-path-mapping-#{@mapping.id}"}
            icon="hero-pencil"
            title="Edit"
            disabled={@runtime?}
            disabled_reason={if(@runtime?, do: "Cannot edit environment-configured mappings")}
            phx-click="edit_path_mapping"
            phx-value-id={@mapping.id}
          />
          <.row_action
            id={"delete-path-mapping-#{@mapping.id}"}
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@runtime?}
            disabled_reason={if(@runtime?, do: "Cannot delete environment-configured mappings")}
            phx-click="delete_path_mapping"
            phx-value-id={@mapping.id}
            data-confirm="Are you sure you want to delete this path mapping?"
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  @doc """
  Renders the Path Mapping modal.
  """
  attr :path_mapping_form, :any, required: true
  attr :path_mapping_mode, :atom, required: true
  attr :remote_suggestions, :list, default: []
  attr :local_suggestions, :list, default: []

  def path_mapping_modal(assigns) do
    ~H"""
    <.admin_modal
      id="path-mapping-modal"
      icon={if @path_mapping_mode == :new, do: "hero-plus-circle", else: "hero-pencil-square"}
      title={if @path_mapping_mode == :new, do: "Add Path Mapping", else: "Edit Path Mapping"}
      subtitle={
        if @path_mapping_mode == :new,
          do: "Configure a new path translation",
          else: "Update path translation"
      }
      on_close="close_path_mapping_modal"
    >
      <.form
        for={@path_mapping_form}
        id="path-mapping-form"
        phx-change="validate_path_mapping"
        phx-submit="save_path_mapping"
      >
        <div class="space-y-5">
          <div>
            <.input
              field={@path_mapping_form[:remote_prefix]}
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
              field={@path_mapping_form[:local_prefix]}
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

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_path_mapping_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary gap-2">
            <.icon name="hero-check" class="w-4 h-4" />
            {if @path_mapping_mode == :new, do: "Add Mapping", else: "Save Changes"}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end
end
