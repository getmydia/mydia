defmodule Mydia.Media do
  @moduledoc """
  The Media context handles movies, TV shows, and episodes. It is a facade of
  `defdelegate`s over `Mydia.Media.Items`, `ItemWrites`, `BulkWrites`,
  `Deletion`, `Episodes`, `EpisodeSync`, `Monitoring`, `Categorization`,
  `Calendar`, `Stats`, `Favorites`, `TitleMatch` and `FileAccess`.
  """

  ## Items

  defdelegate list_media_items(scope, opts \\ []), to: Mydia.Media.Items
  defdelegate media_items_query(scope, opts \\ []), to: Mydia.Media.Items
  defdelegate get_media_item!(scope, id, opts \\ []), to: Mydia.Media.Items
  defdelegate list_items_page(scope, opts \\ []), to: Mydia.Media.Items
  defdelegate list_library_items_page(scope, opts \\ []), to: Mydia.Media.Items
  defdelegate find_by_external_ids(scope, ids, opts \\ []), to: Mydia.Media.Items
  defdelegate find_episode(scope, show_id, season_number, episode_number), to: Mydia.Media.Items
  defdelegate writable?(scope, attrs), to: Mydia.Media.Items
  defdelegate restricted_message(), to: Mydia.Media.Items
  defdelegate create_media_item(scope, attrs \\ %{}, opts \\ []), to: Mydia.Media.Items
  defdelegate fetch_episodes_for_new_show(media_item, opts \\ []), to: Mydia.Media.Items
  defdelegate update_media_item(scope, media_item, attrs, opts \\ []), to: Mydia.Media.Items
  defdelegate change_media_item(media_item, attrs \\ %{}), to: Mydia.Media.Items
  defdelegate change_media_item_category(media_item, attrs \\ %{}), to: Mydia.Media.Items
  defdelegate get_media_status(media_item), to: Mydia.Media.Items
  defdelegate refresh_metadata(media_item, config \\ nil), to: Mydia.Media.Items

  ## Item writes

  defdelegate audited_media_item_fields(), to: Mydia.Media.ItemWrites

  ## Bulk writes

  defdelegate update_media_items_monitored(scope, ids, monitored, opts \\ []),
    to: Mydia.Media.BulkWrites

  defdelegate update_media_items_batch(scope, ids, attrs, opts \\ []),
    to: Mydia.Media.BulkWrites

  ## Deletion

  defdelegate in_use?(media_item, user_id), to: Mydia.Media.Deletion
  defdelegate delete_media_item(scope, media_item, opts \\ []), to: Mydia.Media.Deletion
  defdelegate preview_disk_removal(media_item), to: Mydia.Media.Deletion
  defdelegate delete_media_items(scope, ids, opts \\ []), to: Mydia.Media.Deletion

  ## Episodes

  defdelegate list_episodes(scope, media_item_id, opts \\ []), to: Mydia.Media.Episodes
  defdelegate season_pack_episode_count(media_item_id, season_number), to: Mydia.Media.Episodes
  defdelegate get_episode!(scope, id, opts \\ []), to: Mydia.Media.Episodes

  defdelegate get_episode_by_number(
                scope,
                media_item_id,
                season_number,
                episode_number,
                opts \\ []
              ),
              to: Mydia.Media.Episodes

  defdelegate episode_bounds(media_item_id), to: Mydia.Media.Episodes
  defdelegate episode_coordinates(media_item_id), to: Mydia.Media.Episodes
  defdelegate get_next_episode(scope, episode, opts \\ []), to: Mydia.Media.Episodes
  defdelegate create_episode(attrs \\ %{}), to: Mydia.Media.Episodes
  defdelegate update_episode(episode, attrs), to: Mydia.Media.Episodes
  defdelegate delete_episode(episode), to: Mydia.Media.Episodes
  defdelegate change_episode(episode, attrs \\ %{}), to: Mydia.Media.Episodes

  ## Episode sync

  defdelegate refresh_episodes_for_tv_show(media_item, opts \\ []), to: Mydia.Media.EpisodeSync
  defdelegate refresh_seasons(media_item, season_numbers, opts \\ []), to: Mydia.Media.EpisodeSync
  defdelegate stamp_seasons_refreshed(media_item), to: Mydia.Media.EpisodeSync

  defdelegate upsert_episodes_from_season(media_item, season_data, opts \\ []),
    to: Mydia.Media.EpisodeSync

  ## Monitoring

  defdelegate update_season_monitoring(media_item_id, season_number, monitored),
    to: Mydia.Media.Monitoring

  defdelegate monitoring_presets(), to: Mydia.Media.Monitoring
  defdelegate derive_monitoring_preset(episodes), to: Mydia.Media.Monitoring
  defdelegate apply_episode_monitoring(media_item, preset), to: Mydia.Media.Monitoring
  defdelegate set_monitor_new_seasons(media_item, mode), to: Mydia.Media.Monitoring
  defdelegate season_monitoring_state(episodes), to: Mydia.Media.Monitoring

  defdelegate should_monitor_new_episode?(media_item, season_number),
    to: Mydia.Media.Monitoring

  ## Category classification

  defdelegate update_category(scope, media_item, category, opts \\ []),
    to: Mydia.Media.Categorization

  defdelegate clear_category_override(media_item), to: Mydia.Media.Categorization
  defdelegate reclassify_media_item(media_item, opts \\ []), to: Mydia.Media.Categorization
  defdelegate reclassify_all_media_items(), to: Mydia.Media.Categorization
  defdelegate reclassify_media_items(ids, opts \\ []), to: Mydia.Media.Categorization
  defdelegate partition_for_auto_search(ids), to: Mydia.Media.Categorization

  ## Calendar

  defdelegate list_episodes_by_air_date(scope, start_date, end_date, opts \\ []),
    to: Mydia.Media.Calendar

  defdelegate list_movies_by_release_date(scope, start_date, end_date, opts \\ []),
    to: Mydia.Media.Calendar

  ## Stats

  defdelegate count_media_items(scope, opts \\ []), to: Mydia.Media.Stats
  defdelegate count_movies(scope, opts \\ []), to: Mydia.Media.Stats
  defdelegate count_tv_shows(scope, opts \\ []), to: Mydia.Media.Stats
  defdelegate count_unrated_items(scope), to: Mydia.Media.Stats
  defdelegate episode_state_counts(), to: Mydia.Media.Stats
  defdelegate get_library_status_map(scope), to: Mydia.Media.Stats
  defdelegate library_status_for_tmdb_ids(scope, tmdb_ids, type), to: Mydia.Media.Stats

  ## Favorites

  defdelegate is_favorite?(scope, user_id, media_item_id), to: Mydia.Media.Favorites
  defdelegate toggle_favorite(user_id, media_item_id), to: Mydia.Media.Favorites
  defdelegate list_user_favorites(scope, user_id, opts \\ []), to: Mydia.Media.Favorites

  ## Title matching

  defdelegate recover_provider_id_by_title(media_item, media_type, config \\ nil),
    to: Mydia.Media.TitleMatch

  defdelegate calculate_title_match_score(result, media_item), to: Mydia.Media.TitleMatch
  defdelegate exact_title_match?(result_title, search_title), to: Mydia.Media.TitleMatch
  defdelegate year_matches?(result_year, media_year), to: Mydia.Media.TitleMatch

  ## File access

  @doc "See `Mydia.Media.FileAccess.authorize/2`."
  defdelegate authorize_media_file(scope, media_file), to: Mydia.Media.FileAccess, as: :authorize

  @doc "See `Mydia.Media.FileAccess.authorize_id/2`."
  defdelegate authorize_media_file_id(scope, media_file_id),
    to: Mydia.Media.FileAccess,
    as: :authorize_id
end
