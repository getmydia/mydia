defmodule Mydia.Library do
  @moduledoc """
  The Library context handles media files and library management. It is a
  facade of `defdelegate`s over `Mydia.Library.MediaFiles`, `Analysis`, `Trash`,
  `EpisodeLinks`, `Rescan`, `ScanTriggers`, `DownloadImports` and `ImportRuns`.
  """

  ## Media files

  defdelegate total_storage_bytes(), to: Mydia.Library.MediaFiles
  defdelegate media_file_count(), to: Mydia.Library.MediaFiles
  defdelegate list_media_files(opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate list_media_ids_in_library_path(library_path), to: Mydia.Library.MediaFiles
  defdelegate get_media_file!(id, opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate get_media_file(id, opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate get_media_file_by_path(absolute_path, opts \\ []), to: Mydia.Library.MediaFiles

  defdelegate get_media_file_by_relative_path(library_path_id, relative_path, opts \\ []),
    to: Mydia.Library.MediaFiles

  defdelegate list_media_files_by_relative_path(library_path_id, relative_path, opts \\ []),
    to: Mydia.Library.MediaFiles

  defdelegate episode_has_media_file?(episode_id), to: Mydia.Library.MediaFiles
  defdelegate create_media_file(attrs \\ %{}), to: Mydia.Library.MediaFiles
  defdelegate attach_candidate(candidate_id, target), to: Mydia.Library.MediaFiles
  defdelegate create_scanned_media_file(attrs \\ %{}), to: Mydia.Library.MediaFiles
  defdelegate update_media_file(media_file, attrs), to: Mydia.Library.MediaFiles
  defdelegate update_media_file_scan(media_file, attrs), to: Mydia.Library.MediaFiles
  defdelegate verify_media_file(media_file), to: Mydia.Library.MediaFiles
  defdelegate change_media_file(media_file, attrs \\ %{}), to: Mydia.Library.MediaFiles
  defdelegate get_media_files_for_item(media_item_id, opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate get_media_files_for_episode(episode_id, opts \\ []), to: Mydia.Library.MediaFiles

  ## Analysis

  defdelegate apply_analysis(media_file, outcome), to: Mydia.Library.Analysis
  defdelegate reset_analysis_state(media_file), to: Mydia.Library.Analysis
  defdelegate refresh_file_metadata(media_file), to: Mydia.Library.Analysis
  defdelegate refresh_file_metadata_by_id(media_file_id), to: Mydia.Library.Analysis
  defdelegate repair_file_metadata(media_file), to: Mydia.Library.Analysis
  defdelegate apply_repair_analysis_for_test(media_file, result), to: Mydia.Library.Analysis
  defdelegate refresh_all_file_metadata(), to: Mydia.Library.Analysis

  ## Trash

  defdelegate delete_media_file(media_file, opts \\ []), to: Mydia.Library.Trash
  defdelegate trash_media_file(media_file, opts \\ []), to: Mydia.Library.Trash
  defdelegate restore_media_file(media_file), to: Mydia.Library.Trash
  defdelegate purge_old_trashed_media_files(days \\ 30), to: Mydia.Library.Trash
  defdelegate empty_trash(), to: Mydia.Library.Trash
  defdelegate list_trashed_media_files(opts \\ []), to: Mydia.Library.Trash
  defdelegate count_trashed_media_files(), to: Mydia.Library.Trash
  defdelegate trashed_summary(), to: Mydia.Library.Trash
  defdelegate purge_media_file(media_file), to: Mydia.Library.Trash
  defdelegate get_trashed_media_file(id, opts \\ []), to: Mydia.Library.Trash
  defdelegate delete_media_file_from_disk(media_file), to: Mydia.Library.Trash
  defdelegate delete_path_from_disk(absolute_path), to: Mydia.Library.Trash

  ## Episode links

  defdelegate match_files_to_episodes(media_item_id), to: Mydia.Library.EpisodeLinks
  defdelegate link_file_to_episodes(media_file, episodes), to: Mydia.Library.EpisodeLinks
  defdelegate add_episode_links(media_file, episode_ids), to: Mydia.Library.EpisodeLinks
  defdelegate ensure_episode_link(media_file), to: Mydia.Library.EpisodeLinks

  ## Rescan

  defdelegate rescan_series(media_item_id), to: Mydia.Library.Rescan
  defdelegate rescan_season(media_item_id, season_number), to: Mydia.Library.Rescan
  defdelegate rescan_movie(media_item_id), to: Mydia.Library.Rescan

  ## Scan triggers

  defdelegate trigger_library_scan(library_path_id), to: Mydia.Library.ScanTriggers
  defdelegate trigger_full_library_scan(opts \\ []), to: Mydia.Library.ScanTriggers
  defdelegate trigger_metadata_refresh(media_item_id, opts \\ []), to: Mydia.Library.ScanTriggers
  defdelegate trigger_full_metadata_refresh(), to: Mydia.Library.ScanTriggers

  ## Download imports

  defdelegate torrent_already_imported?(client_name, client_id),
    to: Mydia.Library.DownloadImports

  defdelegate imported_torrent_pairs(pairs), to: Mydia.Library.DownloadImports
  defdelegate origin_download(media_file), to: Mydia.Library.DownloadImports

  defdelegate list_media_files_for_download(download, opts \\ []),
    to: Mydia.Library.DownloadImports

  defdelegate count_imported_files_by_download(download_ids), to: Mydia.Library.DownloadImports

  ## Import runs

  defdelegate create_import_run(attrs), to: Mydia.Library.ImportRuns
  defdelegate start_review_scans(target, user_id), to: Mydia.Library.ImportRuns
  defdelegate get_import_run(id), to: Mydia.Library.ImportRuns
  defdelegate active_import_run(library_path_id), to: Mydia.Library.ImportRuns
  defdelegate last_import_run(library_path_id), to: Mydia.Library.ImportRuns
  defdelegate update_import_run(run, attrs), to: Mydia.Library.ImportRuns
  defdelegate list_active_import_runs(), to: Mydia.Library.ImportRuns
  defdelegate request_import_run_stop(run_or_id), to: Mydia.Library.ImportRuns
  defdelegate import_run_stopping?(run_or_id), to: Mydia.Library.ImportRuns
end
