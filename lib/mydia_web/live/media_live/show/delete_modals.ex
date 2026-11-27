defmodule MydiaWeb.MediaLive.Show.DeleteModals do
  @moduledoc """
  File and season delete confirmation modals for the MediaLive.Show page.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  @doc """
  File delete confirmation modal for removing a media file.

  Three-way choice: leave the file on disk, move it to trash (the default),
  or delete it permanently. Trashing goes through
  `Mydia.Library.trash_media_file/2` with `reason: :manual`, so the file stays
  recoverable from the trash page until it is purged. Only "Delete
  permanently" is irreversible.
  """
  attr :file_to_delete, :map, required: true
  attr :file_delete_mode, :atom, required: true

  def file_delete_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">{gettext("Delete Media File?")}</h3>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-mono text-base-content/70 break-all">
            {Mydia.Library.MediaFile.absolute_path(@file_to_delete)}
          </p>
          <p class="text-sm mt-2">
            <span class="font-semibold">{gettext("Size:")}</span>
            {format_file_size(@file_to_delete.size)}
          </p>
        </div>

        <.delete_mode_options
          mode={@file_delete_mode}
          form_id="file-delete-form"
          change_event="toggle_file_delete_mode"
        />

        <div class="modal-action">
          <button type="button" phx-click="hide_file_delete_confirm" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button
            id="file-delete-confirm"
            type="button"
            phx-click="delete_media_file"
            class={["btn", confirm_class(@file_delete_mode)]}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            {confirm_label(@file_delete_mode)}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_file_delete_confirm"></div>
    </div>
    """
  end

  @doc """
  The three-way delete mode radio group shared by the per-file and the season
  delete dialogs. The form posts `file_delete_mode` with `library_only`,
  `trash` or `permanent`; extra fields can ride along through the inner block.
  """
  attr :mode, :atom, required: true
  attr :form_id, :string, required: true
  attr :change_event, :string, required: true
  slot :inner_block

  def delete_mode_options(assigns) do
    ~H"""
    <form id={@form_id} phx-change={@change_event}>
      <div class="space-y-2.5 mb-5">
        <label class={[
          "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
          @mode == :library_only && "border-primary bg-primary/10",
          @mode != :library_only && "border-base-300 hover:border-primary/50"
        ]}>
          <input
            type="radio"
            name="file_delete_mode"
            value="library_only"
            class="radio radio-primary mt-0.5 flex-shrink-0"
            checked={@mode == :library_only}
          />
          <div>
            <div class="font-medium mb-1">
              {gettext("Remove from library, leave the file on disk")}
            </div>
            <div class="text-sm opacity-75">
              {gettext("A later scan will find the file again and re-import it")}
            </div>
          </div>
        </label>

        <label class={[
          "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
          @mode == :trash && "border-warning bg-warning/10",
          @mode != :trash && "border-base-300 hover:border-warning/50"
        ]}>
          <input
            type="radio"
            name="file_delete_mode"
            value="trash"
            class="radio radio-warning mt-0.5 flex-shrink-0"
            checked={@mode == :trash}
          />
          <div>
            <div class="font-medium mb-1">{gettext("Move to trash")}</div>
            <div class="text-sm opacity-75">
              {gettext("Recoverable from Configuration > Trash until it is purged")}
            </div>
          </div>
        </label>

        <label class={[
          "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
          @mode == :permanent && "border-error bg-error/10",
          @mode != :permanent && "border-base-300 hover:border-error/50"
        ]}>
          <input
            type="radio"
            name="file_delete_mode"
            value="permanent"
            class="radio radio-error mt-0.5 flex-shrink-0"
            checked={@mode == :permanent}
          />
          <div>
            <div class="font-medium mb-1">{gettext("Delete permanently")}</div>
            <div class="text-sm opacity-75 flex items-center gap-1">
              <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
              <span>{gettext("Erases the file now, with no way to undo it")}</span>
            </div>
          </div>
        </label>
      </div>
      {render_slot(@inner_block)}
    </form>
    """
  end

  attr :season_delete, :map, required: true

  def season_delete_confirm_modal(assigns) do
    ~H"""
    <div id="season-delete-modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">
          {gettext("Delete files for season %{number}?", number: @season_delete.season_number)}
        </h3>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm">
            {ngettext(
              "%{count} file",
              "%{count} files",
              @season_delete.file_count
            )}
            <span class="text-base-content/70">
              ({format_file_size(@season_delete.bytes)})
            </span>
          </p>
        </div>

        <.delete_mode_options
          mode={@season_delete.mode}
          form_id="season-delete-form"
          change_event="change_season_delete"
        >
          <input type="hidden" name="unmonitor" value="false" />
          <label class="flex items-center gap-3 cursor-pointer mb-5">
            <input
              id="season-delete-unmonitor"
              type="checkbox"
              name="unmonitor"
              value="true"
              class="checkbox checkbox-sm"
              checked={@season_delete.unmonitor}
            />
            <span class="text-sm">{gettext("Stop monitoring this season")}</span>
          </label>
        </.delete_mode_options>

        <div class="modal-action">
          <button type="button" phx-click="hide_season_delete_confirm" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button
            id="season-delete-confirm"
            type="button"
            phx-click="delete_season_files"
            class={["btn", confirm_class(@season_delete.mode)]}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            {confirm_label(@season_delete.mode)}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_season_delete_confirm"></div>
    </div>
    """
  end

  defp confirm_class(:permanent), do: "btn-error"
  defp confirm_class(:trash), do: "btn-warning"
  defp confirm_class(:library_only), do: "btn-primary"

  defp confirm_label(:permanent), do: gettext("Delete permanently")
  defp confirm_label(:trash), do: gettext("Move to trash")
  defp confirm_label(:library_only), do: gettext("Remove from library")
end
