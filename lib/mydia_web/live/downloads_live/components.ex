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
          :for={{candidate, index} <- Enum.with_index(@modal.candidates)}
          class="flex items-start gap-3 bg-base-200 rounded-lg px-3 py-2"
        >
          <%!--
            The path travels as a hidden input's VALUE, never as part of a
            form field NAME. Plug's query decoder splits a bracketed field
            name on "][", so a name built from a path like
            ".../[Bluray-1080p][Opus 2.0]/ep01.mkv" (the normal shape of an
            anime release) would decode into nested garbage instead of a
            flat map, and the operator's selection would silently vanish.
            Keying everything on the candidate's index sidesteps that
            entirely — see MydiaWeb.DownloadsLive.Index.match_files_import
            for the server-side reassembly.
          --%>
          <input type="hidden" name={"target_path[#{index}]"} value={candidate["path"]} />
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
                name={"target[#{index}]"}
                disabled={candidate["missing"]}
                class="select select-bordered select-sm w-56"
              >
                <option value="">Ignore</option>
                <option value="movie">Import as this movie</option>
              </select>
            <% :tv_show -> %>
              <select
                name={"target[#{index}]"}
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
          title={reject_hint(@modal.download)}
          data-confirm="Blacklist this release, remove the download and its data from the download client, and search again. Files already imported to the library are kept."
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

  @doc """
  The match / re-match dialog.

  One panel holds library rows, then provider rows for titles not yet in the
  library. TV rows behave differently per mode, which the dialog states in
  words rather than leaving the operator to discover by clicking.
  """
  attr :dialog, :map, required: true

  def match_modal(assigns) do
    ~H"""
    <.modal id="match-modal" show={true} on_cancel="close_match_modal">
      <:title>
        {if @dialog.mode == :inflight, do: "Change match", else: "Re-match download"}
      </:title>

      <%= if @dialog.selected do %>
        <p class="text-sm text-base-content/80">
          Choose the episode for <span class="font-medium">{@dialog.selected.title}</span>:
        </p>
        <p :if={@dialog.mode == :postimport} class="text-xs text-base-content/50 mt-1">
          This download imported one file, so it maps to a single episode.
        </p>
        <div :if={@dialog.episodes == []} class="text-sm text-base-content/50 mt-2">
          No episodes found for this show.
        </div>
        <div class="mt-2 max-h-64 overflow-y-auto flex flex-col gap-1">
          <button
            :for={ep <- @dialog.episodes}
            id={"match-dialog-episode-#{ep.id}"}
            type="button"
            class="btn btn-sm btn-ghost justify-start"
            phx-click="match_modal_pick_episode"
            phx-value-episode_id={ep.id}
          >
            S{String.pad_leading("#{ep.season_number}", 2, "0")}E{String.pad_leading(
              "#{ep.episode_number}",
              2,
              "0"
            )}
            <span :if={ep.title} class="text-base-content/60">- {ep.title}</span>
          </button>
        </div>
      <% else %>
        <div class="filter mb-3">
          <input
            id="match-dialog-type-tv"
            class="btn btn-sm"
            type="checkbox"
            name="match_type"
            aria-label="TV"
            checked={@dialog.type == :tv_show}
            phx-click="match_modal_set_type"
            phx-value-type="tv_show"
          />
          <input
            id="match-dialog-type-movie"
            class="btn btn-sm"
            type="checkbox"
            name="match_type"
            aria-label="Movie"
            checked={@dialog.type == :movie}
            phx-click="match_modal_set_type"
            phx-value-type="movie"
          />
        </div>

        <form id="match-modal-search-form" phx-change="match_modal_search">
          <input
            type="text"
            name="q"
            value={@dialog.query}
            class="input input-bordered w-full"
            phx-debounce="300"
            autocomplete="off"
            placeholder="Search your library or add a new title..."
          />
        </form>

        <p :if={@dialog.search_warning} id="match-dialog-warning" class="text-warning text-xs mt-2">
          {@dialog.search_warning}
        </p>

        <p :if={@dialog.error} id="match-dialog-error" class="alert alert-error mt-3 text-sm">
          {@dialog.error}
        </p>

        <div class="mt-2 max-h-64 overflow-y-auto flex flex-col gap-1">
          <div
            :for={item <- @dialog.library_results}
            class="flex items-center gap-1"
          >
            <button
              id={"match-dialog-result-#{item.id}"}
              type="button"
              class="btn btn-sm btn-ghost justify-start grow"
              phx-click="match_modal_pick_item"
              phx-value-media_item_id={item.id}
            >
              <span class="font-medium">{item.title}</span>
              <span :if={item.year} class="text-base-content/60">({item.year})</span>
              <span class="badge badge-xs badge-outline">
                {if item.type == "tv_show", do: "TV", else: "Movie"}
              </span>
            </button>
            <button
              :if={item.type == "tv_show" and @dialog.mode == :inflight}
              id={"match-dialog-pick-episode-#{item.id}"}
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="match_modal_show_episodes"
              phx-value-media_item_id={item.id}
              title="Match a single episode instead of the whole show"
            >
              Pick episode
            </button>
          </div>
        </div>

        <div :if={@dialog.external_results != []} class="divider text-xs my-1">
          Not in your library
        </div>

        <div class="max-h-64 overflow-y-auto flex flex-col gap-1">
          <button
            :for={result <- @dialog.external_results}
            id={"match-dialog-add-#{result.provider_id}"}
            type="button"
            class="btn btn-sm btn-ghost justify-start"
            disabled={@dialog.adding == to_string(result.provider_id)}
            phx-click="match_modal_add_external"
            phx-value-provider_id={result.provider_id}
          >
            <span
              :if={@dialog.adding == to_string(result.provider_id)}
              class="loading loading-spinner loading-xs"
            ></span>
            <span class="font-medium">{result.title}</span>
            <span :if={result.year} class="text-base-content/60">({result.year})</span>
            <span class="badge badge-xs badge-outline">Add to library</span>
          </button>
        </div>
      <% end %>

      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_match_modal">
          Cancel
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

  defp skip_label("not_video_extension"), do: "unsupported file type for this library"
  defp skip_label(reason) when is_binary(reason), do: reason
  defp skip_label(_reason), do: nil

  defp probe_label(%{"status" => "media", "detail" => detail}), do: "Media (#{detail})"
  defp probe_label(%{"status" => "not_media", "detail" => detail}), do: "Not media (#{detail})"
  defp probe_label(%{"detail" => detail}), do: "Unknown (#{detail})"
  defp probe_label(_probe), do: nil

  defp reject_hint(download) do
    case Blacklists.extract_key(download) do
      {:ok, _indexer, _guid} -> "Blacklist this release and search again"
      {:error, :no_indexer} -> "Remove this download and search again (no indexer to blacklist)"
      {:error, :no_guid} -> "Remove this download and search again (no release id to blacklist)"
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
