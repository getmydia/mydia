defmodule MydiaWeb.MediaLive.Show.RenameModal do
  @moduledoc """
  The show page's rename modal: current and proposed filenames, grouped by
  season for TV shows, with a checkbox per file and per season.
  """

  use MydiaWeb, :html

  alias MydiaWeb.MediaLive.Show.RenameSelection

  attr :rename_previews, :list, required: true
  attr :rename_selected, :any, required: true
  attr :renaming_files, :boolean, required: true

  def rename_files_modal(assigns) do
    assigns =
      assigns
      |> assign(:groups, RenameSelection.groups(assigns.rename_previews))
      |> assign(:selected_count, MapSet.size(assigns.rename_selected))

    ~H"""
    <div class="modal modal-open" id="rename-files-modal">
      <div class="modal-box max-w-4xl max-h-[85vh] flex flex-col p-0">
        <div class="sticky top-0 z-10 bg-base-100 border-b border-base-300 px-4 py-3">
          <div class="flex items-center justify-between gap-4">
            <h3 class="text-lg font-bold">Rename Files</h3>
            <button
              type="button"
              phx-click="hide_rename_modal"
              class="btn btn-ghost btn-xs btn-circle"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-y-auto p-3">
          <%= if @rename_previews == [] do %>
            <div class="flex flex-col items-center justify-center py-12 text-center">
              <.icon name="hero-exclamation-circle" class="w-12 h-12 text-base-content/20 mb-3" />
              <h3 class="text-lg font-semibold text-base-content/70 mb-1">No Files to Rename</h3>
              <p class="text-sm text-base-content/50">There are no media files to rename.</p>
            </div>
          <% else %>
            <div class="space-y-3">
              <.rename_group
                :for={{season, previews} <- @groups}
                season={season}
                previews={previews}
                selected={@rename_selected}
              />
            </div>
          <% end %>
        </div>

        <div class="sticky bottom-0 bg-base-100 border-t border-base-300 px-4 py-2">
          <%= if @rename_previews == [] do %>
            <button type="button" phx-click="hide_rename_modal" class="btn btn-ghost btn-sm">
              Close
            </button>
          <% else %>
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="flex items-center gap-3 text-xs text-base-content/70">
                <span id="rename-selected-count">{@selected_count} selected</span>
                <button
                  type="button"
                  id="rename-select-all"
                  phx-click="select_all_rename"
                  class="link link-hover"
                  disabled={@renaming_files}
                >
                  Select all
                </button>
                <button
                  type="button"
                  id="rename-clear"
                  phx-click="clear_rename_selection"
                  class="link link-hover"
                  disabled={@renaming_files}
                >
                  Clear
                </button>
              </div>
              <div class="flex gap-2">
                <button
                  type="button"
                  phx-click="hide_rename_modal"
                  class="btn btn-ghost btn-sm"
                  disabled={@renaming_files}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  id="rename-confirm"
                  phx-click="confirm_rename_files"
                  class="btn btn-primary btn-sm"
                  disabled={@renaming_files or @selected_count == 0}
                >
                  <%= if @renaming_files do %>
                    <span class="loading loading-spinner loading-xs"></span> Renaming...
                  <% else %>
                    <.icon name="hero-check" class="w-4 h-4" /> Rename
                  <% end %>
                </button>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_rename_modal"></div>
    </div>
    """
  end

  attr :season, :any, required: true
  attr :previews, :list, required: true
  attr :selected, :any, required: true

  defp rename_group(assigns) do
    changed = Enum.filter(assigns.previews, & &1.changed?)

    assigns =
      assigns
      |> assign(:changed_count, length(changed))
      |> assign(:unchanged_count, length(assigns.previews) - length(changed))
      |> assign(:picked, Enum.count(changed, &MapSet.member?(assigns.selected, &1.file_id)))
      |> assign(:state, RenameSelection.season_state(assigns.selected, assigns.previews))

    ~H"""
    <section id={@season && "rename-season-#{@season}"}>
      <%!-- Movies form a single nil group: no header, rows only. --%>
      <div
        :if={not is_nil(@season) and @changed_count == 0}
        class="flex items-center gap-2 px-1 py-1 text-xs text-base-content/50"
      >
        <span class="badge badge-ghost badge-sm font-semibold">S{@season}</span>
        All {length(@previews)} files already match
      </div>
      <label
        :if={not is_nil(@season) and @changed_count > 0}
        class="flex items-center gap-2 px-1 py-1 cursor-pointer"
      >
        <input
          type="checkbox"
          id={"rename-season-#{@season}-toggle"}
          class="checkbox checkbox-sm checkbox-primary"
          checked={@state == :all}
          phx-click="toggle_rename_season"
          phx-value-season-number={@season}
        />
        <span class="badge badge-primary badge-sm font-semibold">S{@season}</span>
        <span class="text-xs text-base-content/70">
          {@picked} of {@changed_count} selected<%= if @unchanged_count > 0 do %>
            · {@unchanged_count} unchanged
          <% end %>
        </span>
      </label>

      <div :if={is_nil(@season) or @changed_count > 0} class="space-y-1.5 mt-1">
        <.rename_row :for={preview <- @previews} preview={preview} selected={@selected} />
      </div>
    </section>
    """
  end

  attr :preview, :any, required: true
  attr :selected, :any, required: true

  defp rename_row(assigns) do
    ~H"""
    <label class={[
      "flex items-center gap-2 border border-base-300 rounded-lg p-2 bg-base-100 text-xs",
      @preview.changed? && "cursor-pointer hover:border-primary/40 transition-colors"
    ]}>
      <%= if @preview.changed? do %>
        <input
          type="checkbox"
          id={"rename-file-#{@preview.file_id}"}
          class="checkbox checkbox-xs checkbox-primary"
          checked={MapSet.member?(@selected, @preview.file_id)}
          phx-click="toggle_rename_file"
          phx-value-file-id={@preview.file_id}
        />
      <% else %>
        <span class="badge badge-ghost badge-xs">Same</span>
      <% end %>
      <div class="flex-1 min-w-0">
        <div class="font-mono text-base-content/60 truncate" title={@preview.current_filename}>
          {@preview.current_filename}
        </div>
        <div :if={@preview.changed?} class="flex items-center gap-1 mt-0.5">
          <.icon name="hero-arrow-right" class="w-3 h-3 text-primary flex-shrink-0" />
          <div class="font-mono text-primary font-medium truncate" title={@preview.proposed_filename}>
            {@preview.proposed_filename}
          </div>
        </div>
      </div>
    </label>
    """
  end
end
