defmodule Mydia.Downloads.Queue do
  @moduledoc false
  # Facade over Queue.Lifecycle, Queue.Duplicates, Queue.Rematch,
  # Queue.ClientSelection and Downloads.TorrentFetch.

  alias Mydia.Downloads.Queue.{ClientSelection, Duplicates, Lifecycle, Rematch}

  ## Lifecycle

  defdelegate reject_episodes_in_active_season_packs(episodes), to: Lifecycle
  defdelegate initiate_download(search_result, opts \\ []), to: Lifecycle
  defdelegate cancel_download(download, opts \\ []), to: Lifecycle
  defdelegate reject_release(download, opts \\ []), to: Lifecycle
  defdelegate blacklist_release(download, opts), to: Lifecycle
  defdelegate cancel_bans_release?(download), to: Lifecycle
  defdelegate blacklist_if_stalled(download), to: Lifecycle
  defdelegate pause_download(download, opts \\ []), to: Lifecycle
  defdelegate resume_download(download, opts \\ []), to: Lifecycle
  defdelegate clear_completed(download, opts \\ []), to: Lifecycle
  defdelegate clear_all_completed(opts \\ []), to: Lifecycle
  defdelegate dismiss_download(download), to: Lifecycle

  ## Duplicates

  defdelegate normalize_search_result_metadata(search_result), to: Duplicates
  defdelegate check_for_duplicate_download(search_result, opts), to: Duplicates

  defdelegate check_for_active_download(search_result, media_item_id, episode_id, opts \\ []),
    to: Duplicates

  defdelegate blocking_downloads(media_item, context), to: Duplicates

  defdelegate check_for_existing_media_files(search_result, media_item_id, episode_id),
    to: Duplicates

  ## Rematch

  defdelegate manually_match_download(download, media_item_id, episode_id \\ nil), to: Rematch
  defdelegate adopt_external_torrent(torrent, media_item_id, episode_id \\ nil), to: Rematch
  defdelegate resolve_file_mappings(download, mappings), to: Rematch
  defdelegate rematch_imported_download(download, media_item_id, episode_id \\ nil), to: Rematch

  ## Client selection

  defdelegate replacement_search(download), to: ClientSelection
  defdelegate enqueue_search(download), to: ClientSelection
  defdelegate resolve_adapter(client_config), to: ClientSelection
  defdelegate select_and_add_to_client(search_result, opts), to: ClientSelection
  defdelegate resolve_category(client_config, content_type, opts), to: ClientSelection
  defdelegate resolve_content_type(opts), to: ClientSelection
  defdelegate supports_download_type?(client, download_type), to: ClientSelection
  defdelegate build_download_metadata(search_result), to: ClientSelection
  defdelegate client_for(client_name), to: ClientSelection
end
