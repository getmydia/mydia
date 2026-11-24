defmodule MydiaWeb.AdminLibraryPathsLive.MaintenanceModals do
  @moduledoc false
  use MydiaWeb, :html

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Phoenix.LiveView.AsyncResult

  attr :modal, :any, required: true, doc: "`{kind, library_path_id, AsyncResult}` or nil"

  def maintenance_modal(%{modal: nil} = assigns), do: ~H""

  def maintenance_modal(%{modal: {:bulk_rename, _id, %AsyncResult{} = async}} = assigns) do
    assigns = assign(assigns, :async, async)

    ~H"""
    <.admin_modal
      id="bulk-rename-modal"
      icon="hero-pencil-square"
      title={gettext("Rename files")}
      subtitle={gettext("Rename every file in this library to match the naming template")}
      on_close="close_maintenance_modal"
      size={:lg}
    >
      <.preview_state async={@async} id="bulk-rename-loading">
        <:ok :let={preview}>
          <div class="stats stats-vertical sm:stats-horizontal bg-base-200 w-full mb-4">
            <div class="stat py-2">
              <div class="stat-title">{gettext("To rename")}</div>
              <div id="bulk-rename-changed" class="stat-value text-2xl">
                {max(preview.changed - length(preview.conflicts), 0)}
              </div>
            </div>
            <div class="stat py-2">
              <div class="stat-title">{gettext("Already correct")}</div>
              <div class="stat-value text-2xl">{preview.unchanged}</div>
            </div>
            <div class="stat py-2">
              <div class="stat-title">{gettext("Conflicts")}</div>
              <div class="stat-value text-2xl">{length(preview.conflicts)}</div>
            </div>
          </div>

          <div :if={preview.conflicts != []} id="bulk-rename-conflicts" class="mb-4">
            <h4 class="font-semibold text-sm mb-2">
              {gettext("These files will be skipped")}
            </h4>
            <ul class="text-sm space-y-1 max-h-40 overflow-y-auto">
              <li :for={{item, reason} <- preview.conflicts} class="break-all">
                <span class="font-mono">{item.current_filename}</span>
                <span class="text-base-content/60">
                  {conflict_reason(reason)}
                </span>
              </li>
            </ul>
          </div>

          <div :if={preview.sample != []} id="bulk-rename-sample">
            <h4 class="font-semibold text-sm mb-2">{gettext("Sample")}</h4>
            <ul class="text-sm space-y-2 max-h-72 overflow-y-auto">
              <li :for={item <- preview.sample} class="break-all">
                <div class="font-mono text-base-content/60">{item.current_filename}</div>
                <div class="font-mono">
                  <.icon name="hero-arrow-right" class="w-3 h-3" /> {item.proposed_filename}
                </div>
              </li>
            </ul>
          </div>
        </:ok>
      </.preview_state>
      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_maintenance_modal">
          {gettext("Cancel")}
        </button>
        <button
          id="bulk-rename-confirm"
          type="button"
          class="btn btn-primary"
          phx-click="confirm_bulk_rename"
          disabled={rename_count(@async) == 0}
        >
          {ngettext("Rename %{count} file", "Rename %{count} files", rename_count(@async))}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  def maintenance_modal(%{modal: {:sidecar_cleanup, _id, %AsyncResult{} = async}} = assigns) do
    assigns = assign(assigns, :async, async)

    ~H"""
    <.admin_modal
      id="sidecar-cleanup-modal"
      icon="hero-trash"
      title={gettext("Clean up orphaned sidecars")}
      subtitle={gettext("Metadata and artwork files whose video no longer exists")}
      on_close="close_maintenance_modal"
      tone={:error}
      size={:lg}
    >
      <.preview_state async={@async} id="sidecar-cleanup-loading">
        <:ok :let={preview}>
          <p class="text-sm mb-4">
            {ngettext(
              "%{count} file (%{size}) will be moved to:",
              "%{count} files (%{size}) will be moved to:",
              preview.count,
              size: format_file_size(preview.bytes)
            )}
            <span id="sidecar-cleanup-destination" class="font-mono break-all">
              {preview.destination}
            </span>
          </p>
          <div id="sidecar-cleanup-folders" class="space-y-3 max-h-80 overflow-y-auto text-sm">
            <div :for={{dir, paths} <- preview.folders}>
              <div class="font-mono font-semibold break-all">{dir}</div>
              <ul class="font-mono text-base-content/70 break-all">
                <li :for={path <- paths}>{Path.basename(path)}</li>
              </ul>
            </div>
          </div>
        </:ok>
      </.preview_state>
      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_maintenance_modal">
          {gettext("Cancel")}
        </button>
        <button
          id="sidecar-cleanup-confirm"
          type="button"
          class="btn btn-error"
          phx-click="confirm_sidecar_cleanup"
          disabled={cleanup_count(@async) == 0}
        >
          {ngettext(
            "Move %{count} file to trash",
            "Move %{count} files to trash",
            cleanup_count(@async)
          )}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  attr :async, AsyncResult, required: true
  attr :id, :string, required: true
  slot :ok, required: true

  defp preview_state(assigns) do
    ~H"""
    <%= cond do %>
      <% @async.loading -> %>
        <div id={@id} class="flex justify-center py-10">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      <% @async.failed -> %>
        <div id="maintenance-error" role="alert" class="alert alert-error">
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>{failure_message(@async.failed)}</span>
        </div>
      <% @async.ok? -> %>
        {render_slot(@ok, @async.result)}
    <% end %>
    """
  end

  defp rename_count(%AsyncResult{ok?: true, result: %{changed: changed, conflicts: conflicts}}),
    do: max(changed - length(conflicts), 0)

  defp rename_count(_), do: 0

  defp cleanup_count(%AsyncResult{ok?: true, result: %{count: count}}), do: count
  defp cleanup_count(_), do: 0

  defp failure_message(:library_unavailable),
    do: gettext("The library is unavailable. Check that its storage is reachable.")

  defp failure_message(:s3_unsupported),
    do: gettext("Cleaning up sidecars is not supported for S3 libraries.")

  defp failure_message(_), do: gettext("The preview could not be generated.")

  defp conflict_reason(:target_exists), do: gettext("(target file already exists)")
  defp conflict_reason(:duplicate_target), do: gettext("(another file would get the same name)")
end
