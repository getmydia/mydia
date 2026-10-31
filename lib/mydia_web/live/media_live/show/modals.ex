defmodule MydiaWeb.MediaLive.Show.Modals do
  @moduledoc """
  Modal components for the MediaLive.Show page.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  use MydiaWeb, :verified_routes
  import MydiaWeb.CoreComponents
  import MydiaWeb.IndexerComponents
  import MydiaWeb.TrailerComponents
  import MydiaWeb.DateTimeFormat, only: [format: 3]

  # Import the formatting and search helper functions
  import MydiaWeb.MediaLive.Show.Formatters
  import MydiaWeb.Formatters, only: [format_progress: 1, format_file_size: 1]
  import MydiaWeb.MediaLive.Show.SearchHelpers
  import MydiaWeb.MediaLive.Show.ManualSearchComponents

  alias Mydia.Library.Hdr
  alias Mydia.Media.DiskRemoval.Preview
  alias MydiaWeb.MediaLive.Show.ManualSearchFilters

  @doc """
  Delete confirmation modal for removing a media item.

  Lets the user choose between removing the item from the library and
  deleting it from disk. For the latter, `delete_preview` (an `AsyncResult`
  of `Mydia.Media.DiskRemoval.Preview`, or nil before the socket connects)
  names the folders that will go and the ones that will stay.
  """
  attr :media_item, :map, required: true
  attr :delete_files, :boolean, required: true
  attr :delete_preview, :any, default: nil

  def delete_confirm_modal(assigns) do
    ~H"""
    <div id="delete-media-modal" class="modal modal-open">
      <div class="modal-box max-w-lg">
        <h3 class="font-bold text-lg mb-4">
          {gettext("Delete %{title}?", title: @media_item.title)}
        </h3>

        <form id="delete-media-form" phx-change="toggle_delete_files">
          <div class="space-y-2.5 mb-5">
            <label class={[
              "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
              !@delete_files && "border-primary bg-primary/10",
              @delete_files && "border-base-300 hover:border-primary/50"
            ]}>
              <input
                type="radio"
                name="delete_files"
                value="false"
                class="radio radio-primary mt-0.5 flex-shrink-0"
                checked={!@delete_files}
              />
              <div>
                <div class="font-medium mb-1">{gettext("Remove from library only")}</div>
                <div class="text-sm opacity-75">
                  {gettext("Files stay on disk, can be re-imported later")}
                </div>
              </div>
            </label>

            <label class={[
              "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
              @delete_files && "border-error bg-error/10",
              !@delete_files && "border-base-300 hover:border-error/50"
            ]}>
              <input
                type="radio"
                name="delete_files"
                value="true"
                class="radio radio-error mt-0.5 flex-shrink-0"
                checked={@delete_files}
              />
              <div>
                <div class="font-medium mb-1">{gettext("Delete from disk")}</div>
                <div class="text-sm opacity-75 flex items-center gap-1">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4" />
                  <span>{gettext("Permanently deletes all files - cannot be undone")}</span>
                </div>
              </div>
            </label>
          </div>
        </form>

        <div
          :if={@delete_files && @delete_preview}
          id="delete-preview"
          class="mb-5 rounded-lg bg-base-200 p-3.5 text-sm"
        >
          <.async_result :let={preview} assign={@delete_preview}>
            <:loading>
              <div id="delete-preview-loading" class="flex items-center gap-2 opacity-75">
                <span class="loading loading-spinner loading-xs"></span>
                <span>{gettext("Checking folders…")}</span>
              </div>
            </:loading>
            <:failed :let={_reason}>
              <p id="delete-preview-failed" class="opacity-75">
                {gettext(
                  "Couldn't check folders. Folders are removed only if nothing else is in them."
                )}
              </p>
            </:failed>
            <.delete_preview_body preview={preview} />
          </.async_result>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="hide_delete_confirm" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button
            id="delete-media-confirm"
            type="button"
            phx-click="delete_media"
            class={["btn", (@delete_files && "btn-error") || "btn-warning"]}
          >
            <.icon name="hero-trash" class="w-4 h-4" />
            {if @delete_files, do: gettext("Delete Everything"), else: gettext("Remove from Library")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_delete_confirm"></div>
    </div>
    """
  end

  attr :preview, Preview, required: true

  defp delete_preview_body(assigns) do
    ~H"""
    <div class="space-y-3">
      <p
        :if={@preview.remove == [] and @preview.keep == [] and @preview.loose_files == 0}
        id="delete-preview-empty"
        class="opacity-75"
      >
        {gettext("This item has no files on disk.")}
      </p>

      <div :if={@preview.remove != []}>
        <p class="font-medium mb-1">{gettext("Deletes these folders and everything in them:")}</p>
        <ul class="space-y-0.5">
          <li
            :for={{path, index} <- Enum.with_index(@preview.remove)}
            id={"delete-preview-folder-#{index}"}
            class="font-mono text-xs break-all"
          >
            {path}
          </li>
        </ul>
      </div>

      <p
        :for={{{path, blockers}, index} <- Enum.with_index(@preview.keep)}
        id={"delete-preview-kept-#{index}"}
      >
        {gettext(
          "Keeps %{path}: it also holds other media (%{blockers}). Only this item's files are removed there.",
          path: path,
          blockers: blocker_summary(blockers)
        )}
      </p>

      <p :if={@preview.loose_files > 0} id="delete-preview-loose">
        {loose_sentence(@preview)}
      </p>
    </div>
    """
  end

  defp blocker_summary([first | rest]) do
    if rest == [],
      do: blocker_name(first),
      else: gettext("%{name} and others", name: blocker_name(first))
  end

  defp season_quality_suffix(existing) do
    case Enum.reject([existing.resolution, existing.source, existing.codec], &is_nil/1) do
      [] -> ""
      parts -> " · " <> gettext("mostly %{quality}", quality: Enum.join(parts, " "))
    end
  end

  defp blocker_name({:unreadable, rel}),
    do: gettext("%{name} (unreadable)", name: Path.basename(rel))

  defp blocker_name({_kind, rel}), do: Path.basename(rel)

  defp loose_sentence(%Preview{remove: [], keep: [], loose_files: n}),
    do:
      ngettext(
        "Deletes %{count} file. It sits directly in a library folder, so no folder is removed.",
        "Deletes %{count} files. They sit directly in a library folder, so no folder is removed.",
        n
      )

  defp loose_sentence(%Preview{loose_files: n}),
    do:
      ngettext(
        "Also deletes %{count} file outside these folders.",
        "Also deletes %{count} files outside these folders.",
        n
      )

  @doc """
  Provider re-identification picker.

  Shown when a provider switch could not auto-match the show confidently. Lets
  the operator pick the correct show on the target provider, with copy warning
  that confirming re-matches episodes and resets episode watch history.
  """
  attr :provider, :atom, required: true
  attr :candidates, :list, required: true

  def reidentify_modal(assigns) do
    ~H"""
    <div id="reidentify-modal" class="modal modal-open">
      <div class="modal-box max-w-xl">
        <h3 class="font-bold text-lg mb-1">
          {gettext("Re-identify on %{provider}", provider: provider_label(@provider))}
        </h3>
        <p class="text-sm opacity-75 mb-4">
          {gettext(
            "Pick the correct show. Confirming re-matches episodes from %{provider} and resets episode-level watch history for this show.",
            provider: provider_label(@provider)
          )}
        </p>

        <%= if @candidates == [] do %>
          <div class="alert alert-warning mb-4">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>
              {gettext("No results found on %{provider}.", provider: provider_label(@provider))}
            </span>
          </div>
        <% else %>
          <div class="space-y-2 max-h-80 overflow-y-auto mb-2">
            <button
              :for={candidate <- @candidates}
              type="button"
              phx-click="select_reidentify_candidate"
              phx-value-provider_id={to_string(candidate.provider_id)}
              class="btn btn-ghost h-auto w-full justify-start normal-case text-left p-3 rounded-lg border-2 border-base-300 hover:border-primary hover:bg-primary/5"
            >
              <div class="font-medium">
                {candidate.title}
                <span :if={candidate.year} class="opacity-60 font-normal">({candidate.year})</span>
              </div>
              <div class="text-xs opacity-50 font-mono mt-0.5">
                {gettext("%{provider} ID %{id}",
                  provider: provider_label(@provider),
                  id: to_string(candidate.provider_id)
                )}
              </div>
            </button>
          </div>
        <% end %>

        <div class="modal-action">
          <button type="button" phx-click="cancel_reidentify" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_reidentify"></div>
    </div>
    """
  end

  defp provider_label(provider), do: MydiaWeb.MediaLive.Show.Helpers.provider_label(provider)

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

        <form id="file-delete-form" phx-change="toggle_file_delete_mode">
          <div class="space-y-2.5 mb-5">
            <label class={[
              "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer transition-all hover:shadow-sm",
              @file_delete_mode == :library_only && "border-primary bg-primary/10",
              @file_delete_mode != :library_only && "border-base-300 hover:border-primary/50"
            ]}>
              <input
                type="radio"
                name="file_delete_mode"
                value="library_only"
                class="radio radio-primary mt-0.5 flex-shrink-0"
                checked={@file_delete_mode == :library_only}
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
              @file_delete_mode == :trash && "border-warning bg-warning/10",
              @file_delete_mode != :trash && "border-base-300 hover:border-warning/50"
            ]}>
              <input
                type="radio"
                name="file_delete_mode"
                value="trash"
                class="radio radio-warning mt-0.5 flex-shrink-0"
                checked={@file_delete_mode == :trash}
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
              @file_delete_mode == :permanent && "border-error bg-error/10",
              @file_delete_mode != :permanent && "border-base-300 hover:border-error/50"
            ]}>
              <input
                type="radio"
                name="file_delete_mode"
                value="permanent"
                class="radio radio-error mt-0.5 flex-shrink-0"
                checked={@file_delete_mode == :permanent}
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
        </form>

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

  defp confirm_class(:permanent), do: "btn-error"
  defp confirm_class(:trash), do: "btn-warning"
  defp confirm_class(:library_only), do: "btn-primary"

  defp confirm_label(:permanent), do: gettext("Delete permanently")
  defp confirm_label(:trash), do: gettext("Move to trash")
  defp confirm_label(:library_only), do: gettext("Remove from library")

  @doc """
  File details modal showing comprehensive information about a media file.
  """
  attr :file_details, :map, required: true
  attr :file_origin, :map, default: nil
  attr :current_user_id, :string, default: nil
  attr :display, Mydia.TimeDisplay, required: true

  def file_details_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">{gettext("Media File Details")}</h3>

        <div class="space-y-4">
          <%!-- File Path --%>
          <div>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("File Path")}</h4>
            <%!-- display_path/1 returns nil for a fully orphaned row, which
                  rendered an empty box. This modal is the only surface showing
                  a full path now that the card labels rows by basename. --%>
            <p class="text-sm font-mono bg-base-200 p-3 rounded-box break-all">
              {Mydia.Library.MediaFile.display_path(@file_details) ||
                Mydia.Library.MediaFile.display_name(@file_details)}
            </p>
          </div>
          <%!-- Stash-style stream link: opens in the OS video app or pastes
                into VLC, mpv or Infuse. Relative href, so the browser
                resolves the host and Copy yields an absolute URL. --%>
          <div :if={@current_user_id}>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Stream Link")}</h4>
            <div class="flex items-center gap-2 bg-base-200 p-3 rounded-box">
              <a
                id="file-details-stream-link"
                href={MydiaWeb.StreamLink.path(@current_user_id, @file_details)}
                target="_blank"
                rel="noopener"
                class="link link-primary text-sm font-mono truncate flex-1 min-w-0"
              >
                {Mydia.Library.MediaFile.display_name(@file_details)}
              </a>
              <button
                id="file-details-copy-stream-link"
                type="button"
                class="btn btn-sm btn-ghost"
                phx-click={
                  Phoenix.LiveView.JS.dispatch("mydia:copy-href", to: "#file-details-stream-link")
                }
              >
                <.icon name="hero-clipboard-document" class="w-4 h-4" /> {gettext("Copy")}
              </button>
            </div>
            <p class="text-xs text-base-content/60 mt-1">
              {gettext(
                "Opens in your default video app, or paste it into VLC, mpv or Infuse. Anyone with this link can stream the file, so share it like a password."
              )}
            </p>
          </div>
          <%!-- Quality Information --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Resolution")}
              </h4>
              <p class="text-sm">
                <%= if @file_details.resolution do %>
                  <span class="badge badge-primary">{@file_details.resolution}</span>
                <% else %>
                  <span class="text-base-content/50">{gettext("Unknown")}</span>
                <% end %>
              </p>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Size")}</h4>
              <p class="text-sm">{format_file_size(@file_details.size)}</p>
            </div>
          </div>
          <%!-- Codec Information --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Video Codec")}
              </h4>
              <p class="text-sm">{@file_details.codec || gettext("Unknown")}</p>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Audio Codec")}
              </h4>
              <p class="text-sm">{@file_details.audio_codec || gettext("Unknown")}</p>
            </div>
          </div>
          <%!-- Additional Information --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("HDR Format")}
              </h4>
              <p class="text-sm">
                <%= if @file_details.hdr_format || @file_details.dolby_vision_profile do %>
                  <span class="badge badge-accent">
                    {Hdr.display(%Hdr{
                      base: @file_details.hdr_format,
                      dv_profile: @file_details.dolby_vision_profile,
                      bl_compat_id: @file_details.dolby_vision_bl_compat_id
                    })}
                  </span>
                  <%= if @file_details.dolby_vision_profile do %>
                    <span class="badge badge-ghost badge-sm">
                      {gettext("Profile %{profile}", profile: @file_details.dolby_vision_profile)}
                    </span>
                  <% end %>
                <% else %>
                  <span class="text-base-content/50">{gettext("None")}</span>
                <% end %>
              </p>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Bitrate")}</h4>
              <p class="text-sm">
                <%= if @file_details.bitrate do %>
                  {gettext("%{mbps} Mbps", mbps: Float.round(@file_details.bitrate / 1_000_000, 2))}
                <% else %>
                  <span class="text-base-content/50">{gettext("Unknown")}</span>
                <% end %>
              </p>
            </div>
          </div>
          <%!-- Verification Status --%>
          <div>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">
              {gettext("Verification Status")}
            </h4>
            <p class="text-sm">
              <%= if @file_details.verified_at do %>
                <span class="text-success">
                  <.icon name="hero-check-circle" class="w-4 h-4 inline" />
                  {gettext("Verified on %{date}",
                    date: format(@file_details.verified_at, :datetime, @display)
                  )}
                </span>
              <% else %>
                <span class="text-warning">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" /> {gettext(
                    "Not verified"
                  )}
                </span>
              <% end %>
            </p>
          </div>
          <%!-- Where this file came from. A file the matcher attached to the
                wrong item has no other way to explain itself. --%>
          <%= if @file_origin do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Origin")}</h4>
              <p class="text-sm">
                {gettext("Imported from the download %{title}", title: @file_origin.title)}
              </p>
              <%= if @file_origin.metadata["matched_from_client"] do %>
                <p class="text-sm mt-1">
                  <span class="badge badge-warning badge-sm">
                    {gettext("Added outside Mydia")}
                  </span>
                </p>
              <% end %>
              <%= if @file_origin.metadata["match_reason"] do %>
                <p class="text-xs text-base-content/70 mt-1">
                  {@file_origin.metadata["match_reason"]}
                </p>
              <% end %>
            </div>
          <% end %>
          <%!-- Metadata (if present) --%>
          <%= if @file_details.metadata && map_size(@file_details.metadata) > 0 do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Additional Metadata")}
              </h4>
              <pre class="text-xs bg-base-200 p-3 rounded-box overflow-x-auto"><%= Jason.encode!(@file_details.metadata, pretty: true) %></pre>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="hide_file_details" class="btn btn-ghost">
            {gettext("Close")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_file_details"></div>
    </div>
    """
  end

  @doc """
  Download cancel confirmation modal.
  """
  attr :download_to_cancel, :map, required: true

  def download_cancel_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">{gettext("Cancel Download?")}</h3>
        <p class="py-4">{gettext("Are you sure you want to cancel this download?")}</p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-medium">{@download_to_cancel.title}</p>
          <%= if quality = @download_to_cancel.metadata["quality"] do %>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Quality:")}
              <span class="badge badge-sm">{format_download_quality(quality)}</span>
            </p>
          <% end %>
          <%= if @download_to_cancel.progress do %>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Progress:")} {format_progress(@download_to_cancel.progress)}%
            </p>
          <% end %>
        </div>
        <MydiaWeb.SeedingComponents.removal_warning download={@download_to_cancel} />
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          {gettext("The download will be stopped and marked as cancelled.")}
        </p>
        <div class="modal-action">
          <button type="button" phx-click="hide_download_cancel_confirm" class="btn btn-ghost">
            {gettext("Keep Downloading")}
          </button>
          <button type="button" phx-click="cancel_download" class="btn btn-warning">
            {gettext("Cancel Download")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_cancel_confirm"></div>
    </div>
    """
  end

  @doc """
  Download delete confirmation modal for removing a download record.
  """
  attr :download_to_delete, :map, required: true

  def download_delete_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">{gettext("Remove Download?")}</h3>
        <p class="py-4">
          {gettext("Are you sure you want to remove this download from history?")}
        </p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-medium">{@download_to_delete.title}</p>
          <p class="text-sm text-base-content/70 mt-1">
            {gettext("Status:")}
            <span class={[
              "badge badge-sm",
              @download_to_delete.status == "completed" && "badge-success",
              @download_to_delete.status == "failed" && "badge-error",
              @download_to_delete.status == "downloading" && "badge-info",
              @download_to_delete.status == "pending" && "badge-warning"
            ]}>
              {format_download_status(@download_to_delete.status)}
            </span>
          </p>
        </div>
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          {gettext("This will only remove the download record. Downloaded files will remain on disk.")}
        </p>
        <div class="modal-action">
          <button
            type="button"
            phx-click="hide_download_delete_confirm"
            class="btn btn-ghost"
          >
            {gettext("Cancel")}
          </button>
          <button type="button" phx-click="delete_download_record" class="btn btn-error">
            {gettext("Remove Record")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_delete_confirm"></div>
    </div>
    """
  end

  @doc """
  Download details modal showing comprehensive information about a download.
  """
  attr :download_details, :map, required: true
  attr :display, Mydia.TimeDisplay, required: true

  def download_details_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h3 class="font-bold text-lg mb-4">{gettext("Download Details")}</h3>

        <div class="space-y-4">
          <%!-- Title and Status --%>
          <div>
            <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Title")}</h4>
            <p class="text-sm font-medium">{@download_details.title}</p>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Status")}</h4>
              <span class={[
                "badge",
                @download_details.status == "completed" && "badge-success",
                @download_details.status == "failed" && "badge-error",
                @download_details.status == "downloading" && "badge-info",
                @download_details.status == "pending" && "badge-warning"
              ]}>
                {format_download_status(@download_details.status)}
              </span>
            </div>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Quality")}</h4>
              <%= if quality = @download_details.metadata["quality"] do %>
                <span class="badge">{format_download_quality(quality)}</span>
              <% else %>
                <span class="text-base-content/50">{gettext("Unknown")}</span>
              <% end %>
            </div>
          </div>
          <%!-- Progress --%>
          <%= if @download_details.progress do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Progress")}</h4>
              <div class="flex items-center gap-3">
                <progress
                  class="progress progress-primary flex-1"
                  value={@download_details.progress}
                  max="100"
                ></progress>
                <span class="text-sm font-mono">{format_progress(@download_details.progress)}%</span>
              </div>
            </div>
          <% end %>
          <%!-- Source URL --%>
          <%= if @download_details.download_url do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Source URL")}
              </h4>
              <p class="text-xs font-mono bg-base-200 p-3 rounded-box break-all">
                {Mydia.Downloads.Client.Helpers.redact_url(@download_details.download_url)}
              </p>
            </div>
          <% end %>
          <%!-- Error Message --%>
          <%= if @download_details.error_message do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Error Message")}
              </h4>
              <div class="alert alert-error">
                <.icon name="hero-exclamation-circle" class="w-5 h-5" />
                <span class="text-sm">{@download_details.error_message}</span>
              </div>
            </div>
          <% end %>
          <%!-- Timestamps --%>
          <div class="grid grid-cols-2 gap-4">
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">{gettext("Added")}</h4>
              <p class="text-sm">
                {format(@download_details.inserted_at, :datetime, @display)}
              </p>
            </div>
            <%= if @download_details.completed_at do %>
              <div>
                <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                  {gettext("Completed")}
                </h4>
                <p class="text-sm">
                  {format(@download_details.completed_at, :datetime, @display)}
                </p>
              </div>
            <% end %>
          </div>
          <%!-- Metadata (if present) --%>
          <%= if @download_details.metadata && map_size(@download_details.metadata) > 0 do %>
            <div>
              <h4 class="text-sm font-semibold text-base-content/70 mb-2">
                {gettext("Additional Metadata")}
              </h4>
              <pre class="text-xs bg-base-200 p-3 rounded-box overflow-x-auto"><%= Jason.encode!(Mydia.Downloads.Client.Helpers.redact_urls_in(@download_details.metadata), pretty: true) %></pre>
            </div>
          <% end %>
        </div>

        <div class="modal-action">
          <button type="button" phx-click="hide_download_details" class="btn btn-ghost">
            {gettext("Close")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_details"></div>
    </div>
    """
  end

  @doc """
  Manual search modal for searching and downloading content manually.
  Uses DaisyUI list components for a cleaner, more scannable UI.
  """
  attr :manual_search_context, :map, default: nil
  attr :existing, :any, default: nil
  # Downloads that would block any grab here (Mydia.Downloads.blocking_downloads/2).
  attr :blocking, :list, default: []
  attr :media_item, Mydia.Media.MediaItem, required: true
  attr :manual_search_query, :string, required: true
  attr :searching, :boolean, required: true
  attr :close_after_grab, :boolean, default: false
  attr :download_error, :any, default: nil
  attr :results_empty?, :boolean, required: true
  # Whether the accumulated (pre-filter) result pool is still empty. Gates the filters
  # bar; the comment on it below says why this is not `results_empty?`.
  attr :raw_results_empty?, :boolean, default: true
  attr :indexer_progress, :map, default: %{}
  attr :cardigann_summary, Mydia.Indexers.CardigannSummary, default: nil
  attr :streams, :map, required: true
  attr :quality_filters, :list, default: []
  attr :source_filters, :list, default: []
  attr :codec_filters, :list, default: []
  attr :indexer_filters, :list, default: []
  attr :filter_options, :map, default: %{sources: [], codecs: [], indexers: []}
  attr :result_count, :integer, default: 0
  attr :min_seeders, :integer, default: 0
  attr :sort_by, :atom, required: true

  def manual_search_modal(assigns) do
    # Calculate media_type for profile scoring
    media_type =
      case assigns.media_item.type do
        "movie" -> :movie
        "tv_show" -> :episode
        _ -> :movie
      end

    # Build the same ranking options the manual list was ordered with, so the
    # per-result breakdown (including penalties) matches the unified ranker.
    manual_ranking_opts =
      MydiaWeb.MediaLive.Show.SearchHelpers.build_manual_ranking_opts(assigns)

    assigns =
      assigns
      |> assign(:media_type, media_type)
      |> assign(:manual_ranking_opts, manual_ranking_opts)
      # See the comment above the filter controls in the template.
      |> assign(:filters_visible?, !assigns.raw_results_empty? or !assigns.searching)

    ~H"""
    <div class="modal modal-open" id="manual-search-modal">
      <div class={[
        "modal-box relative flex flex-col overflow-hidden p-0",
        "max-sm:h-dvh max-sm:max-h-none max-sm:w-full max-sm:max-w-none max-sm:rounded-none",
        "sm:h-[90vh] sm:max-w-4xl lg:max-w-6xl"
      ]}>
        <%!-- Header --%>
        <div class="navbar min-h-0 shrink-0 gap-2 border-b border-base-300 px-3 py-2 sm:px-4">
          <div class="min-w-0 flex-1">
            <h3 class="text-lg font-bold leading-tight sm:text-xl">{gettext("Manual Search")}</h3>
            <%= if @manual_search_context do %>
              <p class="truncate text-sm text-base-content/70">
                <%= case @manual_search_context.type do %>
                  <% :episode -> %>
                    <span class="text-sm sm:text-base text-base-content/70">
                      {gettext("for Episode")}
                    </span>
                  <% :season -> %>
                    <span class="text-sm sm:text-base text-base-content/70">
                      {gettext("for %{title} - Season %{season}",
                        title: @media_item.title,
                        season: @manual_search_context.season_number
                      )}
                    </span>
                  <% :media_item -> %>
                    <span class="text-sm sm:text-base text-base-content/70">
                      {gettext("for %{title}", title: @media_item.title)}
                    </span>
                  <% _ -> %>
                    <span></span>
                <% end %>
              </p>
            <% end %>
          </div>
          <ManualSearchFilters.sort_menu sort_by={@sort_by} class="lg:hidden" />
          <button
            type="button"
            phx-click="close_manual_search_modal"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Close")}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>
        <div class="shrink-0 space-y-1 border-b border-base-300 px-3 py-2 sm:px-4">
          <%!-- Search Query Display --%>
          <div class="flex items-center gap-2 text-sm">
            <.icon name="hero-magnifying-glass" class="w-4 h-4 text-base-content/60" />
            <span class="text-base-content/70">{gettext("Searching for:")}</span>
            <span class="font-semibold truncate">{@manual_search_query}</span>
          </div>
          <%= if @existing do %>
            <div
              id="manual-search-existing"
              class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm mt-1 min-w-0"
            >
              <.icon name="hero-archive-box" class="w-4 h-4 text-base-content/60 shrink-0" />
              <span class="text-base-content/70 shrink-0">{gettext("On disk:")}</span>
              <%= case @existing.kind do %>
                <% :file -> %>
                  <span
                    class="font-mono text-xs truncate min-w-0 basis-full sm:basis-auto"
                    title={@existing.filename}
                  >
                    {@existing.filename}
                  </span>
                  <span :if={@existing.resolution} class="badge badge-sm badge-ghost shrink-0">
                    {@existing.resolution}
                  </span>
                  <span :if={@existing.codec} class="badge badge-sm badge-ghost shrink-0">
                    {@existing.codec}
                  </span>
                  <span :if={@existing.size} class="text-xs text-base-content/60 shrink-0">
                    {format_file_size(@existing.size)}
                  </span>
                  <span :if={@existing.extra_count > 0} class="text-xs text-base-content/60 shrink-0">
                    {gettext("+%{count} more", count: @existing.extra_count)}
                  </span>
                <% :season -> %>
                  <span class="truncate">
                    {gettext("%{on_disk}/%{total} episodes on disk",
                      on_disk: @existing.on_disk,
                      total: @existing.total
                    )}{season_quality_suffix(@existing)}
                  </span>
              <% end %>
            </div>
          <% end %>
        </div>
        <%!-- Filter controls: chip bar and filter panel --%>
        <%!-- `@filters_visible?` is `!@raw_results_empty? or !@searching`.
             Additive to the old `!@searching` gate. Results now stream in
             indexer by indexer, so gating only on the search being over left
             the user staring at rows they could not filter or re-sort for up
             to the full 120s deadline. Adding "or the accumulated pool is not
             empty" opens the bar as soon as the first indexer reports.

             The extra condition is the PRE-filter pool, not `!@results_empty?`
             (what the results list below uses). `results_empty?` is the
             post-filter display set, so a quality filter that happens to match
             nothing would hide the very controls needed to undo it. Keeping
             `!@searching` as a floor also keeps the "Close after grabbing"
             preference reachable after a search that found nothing. --%>
        <ManualSearchFilters.chip_bar
          :if={@filters_visible?}
          quality_filters={@quality_filters}
          source_filters={@source_filters}
          codec_filters={@codec_filters}
          indexer_filters={@indexer_filters}
          min_seeders={@min_seeders}
        />
        <div class={[
          "flex min-h-0 flex-1 flex-col",
          @filters_visible? &&
            "lg:grid lg:grid-cols-[16rem_minmax(0,1fr)] lg:grid-rows-[minmax(0,1fr)]"
        ]}>
          <ManualSearchFilters.filter_panel
            :if={@filters_visible?}
            quality_filters={@quality_filters}
            source_filters={@source_filters}
            codec_filters={@codec_filters}
            indexer_filters={@indexer_filters}
            filter_options={@filter_options}
            quality_options={quality_options()}
            min_seeders={@min_seeders}
            close_after_grab={@close_after_grab}
            result_count={@result_count}
          />
          <div id="manual-search-results-pane" class="min-h-0 flex-1 overflow-y-auto">
            <%!-- Inline Download Error --%>
            <%= if @download_error do %>
              <div class="alert alert-error mx-4 mt-3 mb-1">
                <.icon name="hero-exclamation-circle" class="w-5 h-5 shrink-0" />
                <span class="text-sm">{@download_error}</span>
              </div>
            <% end %>
            <.blocking_banner
              :if={@blocking != []}
              blocking={@blocking}
              context_type={@manual_search_context && @manual_search_context.type}
            />
            <%!-- Per-indexer search progress, and the active filters from lg --%>
            <div class="px-4 pt-3 lg:flex lg:items-start lg:gap-3">
              <div class="min-w-0 flex-1">
                <.indexer_search_status
                  progress={@indexer_progress}
                  cardigann={@cardigann_summary}
                  retry_event="retry_indexer"
                  retest_paused_event="retest_paused"
                />
              </div>
              <ManualSearchFilters.active_chips
                :if={@filters_visible?}
                id_prefix="manual-search-lg-chip"
                class="hidden flex-wrap justify-end pt-2 lg:flex"
                quality_filters={@quality_filters}
                source_filters={@source_filters}
                codec_filters={@codec_filters}
                indexer_filters={@indexer_filters}
                min_seeders={@min_seeders}
              />
            </div>
            <%!-- Loading State --%>
            <%= if @searching && @results_empty? do %>
              <div
                id="manual-search-loading-state"
                class="flex flex-col items-center justify-center py-16"
              >
                <span class="loading loading-spinner loading-lg text-primary mb-4"></span>
                <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                  {gettext("Searching across indexers...")}
                </h3>
                <p class="text-base-content/50">
                  {gettext("This may take a few seconds")}
                </p>
              </div>
            <% end %>
            <%!-- Empty State: nothing found, or filtered down to nothing --%>
            <%= if @results_empty? && !@searching do %>
              <%= if @raw_results_empty? do %>
                <div class="flex flex-col items-center justify-center py-16 text-center px-4">
                  <.icon
                    name="hero-exclamation-circle"
                    class="w-16 h-16 text-base-content/20 mb-4"
                  />
                  <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                    {gettext("No Results Found")}
                  </h3>
                  <p class="text-base-content/50 max-w-sm mb-4">
                    {gettext("We couldn't find any releases matching \"%{query}\"",
                      query: @manual_search_query
                    )}
                  </p>
                  <div class="text-sm text-base-content/60">
                    <p>
                      {gettext(
                        "Try different keywords, adjusting filters, or checking your indexers."
                      )}
                    </p>
                  </div>
                </div>
              <% else %>
                <div
                  id="manual-search-empty-filtered"
                  class="flex flex-col items-center justify-center px-4 py-16 text-center"
                >
                  <.icon name="hero-funnel" class="mb-4 h-14 w-14 text-base-content/20" />
                  <h3 class="mb-2 text-lg font-semibold text-base-content/70">
                    {gettext("No releases match these filters")}
                  </h3>
                  <button
                    type="button"
                    id="manual-search-empty-clear"
                    class="btn btn-primary btn-sm"
                    phx-click="clear_search_filters"
                  >
                    {gettext("Clear filters")}
                  </button>
                </div>
              <% end %>
            <% end %>
            <%!-- Results List --%>
            <%= if !@results_empty? do %>
              <.results_header
                sort_by={@sort_by}
                profile?={Keyword.get(@manual_ranking_opts, :quality_profile) != nil}
              />
              <ul id="manual-search-results" class="list bg-base-100" phx-update="stream">
                <li
                  :for={{id, result} <- @streams.search_results}
                  id={id}
                  class={[
                    "list-row hover:bg-base-200/50 transition-colors px-4 py-3 border-b border-base-200 last:border-b-0 lg:gap-3",
                    row_grid()
                  ]}
                >
                  <.release_row id={id} result={result} manual_ranking_opts={@manual_ranking_opts} />
                </li>
              </ul>
            <% end %>
          </div>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_manual_search_modal"></div>
    </div>
    """
  end

  @doc """
  Category override modal for changing media item category.
  """
  attr :media_item, :map, required: true
  attr :category_form, :map, required: true
  attr :available_categories, :list, required: true

  def category_override_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">{gettext("Change Category")}</h3>

        <div class="mb-4 p-3 bg-base-200 rounded-box">
          <div class="flex items-center gap-2 text-sm">
            <span class="text-base-content/70">{gettext("Current category:")}</span>
            <%= if @media_item.category do %>
              <.category_badge
                category={@media_item.category}
                override={@media_item.category_override}
              />
            <% else %>
              <span class="text-base-content/50">{gettext("Not set")}</span>
            <% end %>
          </div>
          <%= if @media_item.category_override do %>
            <div class="text-xs text-warning mt-2 flex items-center gap-1">
              <.icon name="hero-exclamation-triangle" class="w-3 h-3" />
              {gettext("Category was manually set and won't change on metadata refresh")}
            </div>
          <% end %>
        </div>

        <.form
          for={@category_form}
          id="category-override-form"
          phx-change="validate_category"
          phx-submit="save_category"
        >
          <div class="form-control mb-4">
            <label class="label">
              <span class="label-text font-medium">{gettext("Select Category")}</span>
            </label>
            <.input
              field={@category_form[:category]}
              type="select"
              options={@available_categories}
              prompt={gettext("Select a category")}
            />
          </div>

          <div class="form-control mb-4">
            <label class="label cursor-pointer justify-start gap-4">
              <.input
                field={@category_form[:category_override]}
                type="checkbox"
                class="checkbox checkbox-primary"
              />
              <div>
                <span class="label-text font-medium">{gettext("Lock category")}</span>
                <p class="label-text-alt mt-1 text-base-content/70">
                  {gettext("Prevent auto-classification from changing this category")}
                </p>
              </div>
            </label>
          </div>

          <div class="modal-action">
            <button type="button" phx-click="hide_category_modal" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
            <%= if @media_item.category_override do %>
              <button
                type="button"
                phx-click="reset_category_to_auto"
                class="btn btn-warning btn-outline"
              >
                <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Reset to Auto")}
              </button>
            <% end %>
            <button type="submit" class="btn btn-primary">
              {gettext("Save Category")}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="hide_category_modal"></div>
    </div>
    """
  end

  @doc """
  Trailer modal for the item's YouTube trailers.

  Takes the list of videos: the player plays the first and falls back to the
  next when YouTube refuses it (see `MydiaWeb.TrailerComponents`).
  """
  attr :videos, :list, required: true

  def trailer_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl p-0 overflow-hidden relative bg-black">
        <button
          type="button"
          phx-click="hide_trailer_modal"
          class="btn btn-circle btn-sm absolute top-2 right-2 z-10 bg-black/50 border-0 hover:bg-black/70"
        >
          <.icon name="hero-x-mark" class="w-5 h-5 text-white" />
        </button>
        <.trailer_player
          id="media-trailer-player"
          videos={@videos}
          autoplay
          button_class="[&.btn-ghost]:text-white/80 [&.btn-ghost]:hover:bg-white/10 [&.btn-ghost]:hover:text-white"
        />
      </div>
      <div class="modal-backdrop bg-black/80" phx-click="hide_trailer_modal"></div>
    </div>
    """
  end
end
