defmodule MydiaWeb.DownloadsLive.Components do
  @moduledoc """
  Components used only by `MydiaWeb.DownloadsLive.Index`.

  Not globally imported. See the component organization rules in CLAUDE.md.
  """
  use MydiaWeb, :html

  alias Mydia.Downloads.Blacklists

  @doc """
  The match-files modal.

  Lets the operator see every file a failed import's download folder actually
  contained (not just "no importable files found") and match any of them to an
  episode, the movie destination, or leave them ignored.
  """
  attr :modal, :map, required: true
  attr :error, :string, default: nil

  def match_files_modal(assigns) do
    assigns = assign(assigns, :target_kind, target_kind(assigns.modal))

    ~H"""
    <.modal id="match-files-modal" show={true} on_cancel="close_match_files">
      <:title>Match files</:title>
      <p class="text-sm text-base-content/60 truncate">{@modal.download.title}</p>

      <p :if={@modal.source == :snapshot} class="alert alert-warning mt-3 text-sm">
        <.icon name="hero-exclamation-triangle" class="size-4" />
        Mydia cannot read this download's folder right now, so this is the listing
        recorded when the import failed.
      </p>

      <p
        :if={@target_kind in [:tv_show_no_episodes, :unmatched]}
        id="match-files-blocked"
        class="alert alert-warning mt-3 text-sm"
      >
        <.icon name="hero-exclamation-triangle" class="size-4" />
        {blocked_reason(@target_kind)}
      </p>

      <p :if={@error} id="match-files-error" class="alert alert-error mt-3 text-sm">
        {@error}
      </p>

      <form id="match-files-form" phx-submit="match_files_import" class="mt-4 space-y-2">
        <div
          :for={candidate <- @modal.candidates}
          class="flex items-start gap-3 bg-base-200 rounded-lg px-3 py-2"
        >
          <div class="flex-1 min-w-0">
            <div
              class={[
                "text-sm font-mono truncate",
                candidate["missing"] && "line-through opacity-50"
              ]}
              title={candidate["path"]}
            >
              {candidate["name"]}
            </div>
            <div class="text-xs text-base-content/50">
              {format_size(candidate["size"])}
              <span :if={candidate["probe"]}>
                • {probe_label(candidate["probe"])}
              </span>
              <span :if={candidate["skip_reason"]}>
                • skipped: {skip_label(candidate["skip_reason"])}
              </span>
            </div>
          </div>
          <%= case @target_kind do %>
            <% :movie -> %>
              <select
                name={"target[#{candidate["path"]}]"}
                disabled={candidate["missing"]}
                class="select select-bordered select-sm w-56"
              >
                <option value="">Ignore</option>
                <option value="movie">Import as this movie</option>
              </select>
            <% :tv_show -> %>
              <select
                name={"target[#{candidate["path"]}]"}
                disabled={candidate["missing"]}
                class="select select-bordered select-sm w-56"
              >
                <option value="">Ignore</option>
                <option
                  :for={episode <- @modal.episodes}
                  value={episode.id}
                  selected={prefilled?(candidate, episode)}
                >
                  {episode_label(episode)}
                </option>
              </select>
            <% _blocked -> %>
              <span class="select select-sm select-bordered w-56 flex items-center text-base-content/40 italic">
                Can't match yet
              </span>
          <% end %>
        </div>
      </form>

      <:actions>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="close_match_files">
          Cancel
        </button>
        <button
          type="button"
          id="match-files-reject"
          class="btn btn-warning btn-sm"
          phx-click="reject_release"
          phx-value-id={@modal.download.id}
          disabled={not rejectable?(@modal.download)}
          title={reject_hint(@modal.download)}
          data-confirm="Blacklist this release, delete it and its files, and search again?"
        >
          Reject release
        </button>
        <button
          type="submit"
          form="match-files-form"
          id="match-files-import"
          class="btn btn-primary btn-sm"
          disabled={@target_kind in [:tv_show_no_episodes, :unmatched]}
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Import selected
        </button>
      </:actions>
    </.modal>
    """
  end

  # Whether the modal's candidates can target a movie destination, an episode,
  # or neither. Deliberately keyed off `download.media_item.type` (authoritative)
  # rather than `episodes == []` — an ordinary TV show whose episodes haven't
  # been fetched yet also has an empty episode list, and treating that the same
  # as "this is a movie" let a file get routed with `episode_id: nil`, which
  # `MediaImport.process_targeted_import/3` places at the *show's* root folder
  # instead of a season folder — an orphaned show-level file reported back to
  # the operator as a successful import.
  defp target_kind(%{download: %{media_item: %{type: "movie"}}}), do: :movie

  defp target_kind(%{download: %{media_item: %{type: "tv_show"}}, episodes: []}),
    do: :tv_show_no_episodes

  defp target_kind(%{download: %{media_item: %{type: "tv_show"}}}), do: :tv_show

  defp target_kind(_modal), do: :unmatched

  defp blocked_reason(:tv_show_no_episodes),
    do:
      "This show's episodes have not been loaded yet, so these files cannot be matched to one. Refresh the show's episode list, then try again."

  defp blocked_reason(:unmatched),
    do: "This download has no matched title, so its files cannot be matched to a destination yet."

  defp prefilled?(candidate, episode) do
    candidate["parsed_season"] == episode.season_number and
      candidate["parsed_episode"] == episode.episode_number
  end

  defp episode_label(episode) do
    season = String.pad_leading("#{episode.season_number}", 2, "0")
    number = String.pad_leading("#{episode.episode_number}", 2, "0")

    if episode.title do
      "S#{season}E#{number} - #{episode.title}"
    else
      "S#{season}E#{number}"
    end
  end

  defp skip_label("not_video_extension"), do: "not a video extension"
  defp skip_label(reason) when is_binary(reason), do: reason
  defp skip_label(_reason), do: nil

  defp probe_label(%{"status" => "media", "detail" => detail}), do: "Media (#{detail})"
  defp probe_label(%{"status" => "not_media", "detail" => detail}), do: "Not media (#{detail})"
  defp probe_label(%{"detail" => detail}), do: "Unknown (#{detail})"
  defp probe_label(_probe), do: nil

  defp rejectable?(download) do
    match?({:ok, _indexer, _guid}, Blacklists.extract_key(download))
  end

  defp reject_hint(download) do
    case Blacklists.extract_key(download) do
      {:ok, _indexer, _guid} -> "Blacklist this release and search again"
      {:error, :no_indexer} -> "No indexer recorded, so this release cannot be blacklisted"
      {:error, :no_guid} -> "No release id recorded, so this release cannot be blacklisted"
    end
  end

  @doc """
  Formats a byte count for display. Returns "—" for `nil`.

  The single formatter for this feature (downloads list + this modal). Public
  so `DownloadsLive.Index`'s template can call `Components.format_size/1`.
  """
  @spec format_size(integer() | nil) :: String.t()
  def format_size(nil), do: "—"

  def format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
end
