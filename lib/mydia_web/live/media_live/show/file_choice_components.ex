defmodule MydiaWeb.MediaLive.Show.FileChoiceComponents do
  @moduledoc """
  The "Choose files…" modal over the manual-search dialog. State and events
  live in `MydiaWeb.MediaLive.Show.FileChoiceEvents`.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]
  import MydiaWeb.FileTreeComponents, only: [file_tree: 1]
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Downloads.{FileSelection, FileTree}
  alias Mydia.Downloads.Queue.FilePreview
  alias MydiaWeb.MediaLive.Show.FileChoiceEvents

  attr :file_choice, :map, required: true

  def file_choice_modal(assigns) do
    ~H"""
    <div id="file-choice-modal" class="modal modal-open" role="dialog" aria-modal="true">
      <div class="modal-box max-w-2xl">
        <h3 class="text-lg font-bold">{gettext("Choose files…")}</h3>
        <p class="mt-1 break-all text-sm text-base-content/70">{@file_choice.title}</p>
        <.loading :if={@file_choice.status == :loading} />
        <.ready :if={@file_choice.status == :ready} file_choice={@file_choice} />
        <.failed :if={match?({:error, _}, @file_choice.status)} status={@file_choice.status} />
      </div>
      <div class="modal-backdrop" phx-click="cancel_file_choice"></div>
    </div>
    """
  end

  defp loading(assigns) do
    ~H"""
    <div id="file-choice-loading" class="flex flex-col items-center gap-2 py-10 text-center">
      <span class="loading loading-spinner loading-lg text-primary"></span>
      <p class="font-medium">{gettext("Fetching the file list…")}</p>
      <p class="text-sm text-base-content/60">{gettext("A magnet link can take a while.")}</p>
    </div>
    <div class="modal-action">
      <.cancel_button />
    </div>
    """
  end

  attr :file_choice, :map, required: true

  defp ready(assigns) do
    %{files: files, selected: selected, preview: preview} = assigns.file_choice
    indexes = MapSet.to_list(selected)
    picked = preview |> FilePreview.auto_selected() |> MapSet.size()

    assigns =
      assign(assigns,
        picked: picked,
        total: length(files),
        size: format_file_size(FileTree.selected_size(files, selected)),
        keeps_video?: FileSelection.keeps_video?(files, indexes)
      )

    ~H"""
    <p id="file-choice-picked" class="mt-3 text-sm">
      {ngettext(
        "Mydia picked %{count} of %{total} file",
        "Mydia picked %{count} of %{total} files",
        @picked,
        total: @total
      )}
    </p>
    <div class="mt-3 max-h-[50vh] overflow-y-auto rounded-box border border-base-300 p-3">
      <.file_tree id="file-choice-tree" files={@file_choice.files} selected={@file_choice.selected} />
    </div>
    <p :if={not @keeps_video?} id="file-choice-no-video" class="mt-2 text-sm text-error">
      {gettext("Choose at least one video file.")}
    </p>
    <div class="modal-action">
      <.cancel_button />
      <button
        id="file-choice-confirm"
        type="button"
        class="btn btn-primary"
        phx-click="confirm_file_choice"
        disabled={not @keeps_video?}
      >
        <.icon name="hero-arrow-down-tray" class="size-4" />
        {gettext("Download selected (%{size})", size: @size)}
      </button>
    </div>
    """
  end

  attr :status, :any, required: true

  defp failed(assigns) do
    {:error, reason} = assigns.status
    assigns = assign(assigns, :message, FileChoiceEvents.error_message(reason))

    ~H"""
    <div role="alert" id="file-choice-error" class="alert alert-warning mt-4">
      <.icon name="hero-exclamation-triangle" class="size-5" />
      <span>{@message}</span>
    </div>
    <div class="modal-action">
      <.cancel_button />
      <button
        id="file-choice-auto"
        type="button"
        class="btn btn-primary"
        phx-click="download_auto_from_choice"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" />
        {gettext("Download with automatic selection")}
      </button>
    </div>
    """
  end

  defp cancel_button(assigns) do
    ~H"""
    <button id="file-choice-cancel" type="button" class="btn btn-ghost" phx-click="cancel_file_choice">
      {gettext("Cancel")}
    </button>
    """
  end
end
