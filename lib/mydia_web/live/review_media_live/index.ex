defmodule MydiaWeb.ReviewMediaLive.Index do
  @moduledoc """
  Review: work the unresolved files of one library, grouped by series/season.

  There is no pagination and no session state: the group is a live query over
  the inbox (`Library.group_inbox_files/1`), re-read after every mutation, so
  approving a row removes it with nothing to persist.
  """
  use MydiaWeb, :live_view

  alias Mydia.{Library, Metadata, Settings}
  alias Mydia.Library.{FileGrouper, FileIngest, ImportRun, MediaFile}
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.ImportMediaLive.Components, as: ImportComponents
  alias MydiaWeb.ReviewMediaLive.Components

  @media_types ~w(movie tv_show)
  @default_media_type "movie"

  @impl true
  def mount(_params, _session, socket) do
    library_paths =
      Settings.list_library_paths()
      |> Enum.filter(&ImportRun.importable_type?(&1.type))
      |> Enum.map(fn path ->
        %{
          id: path.id,
          path: path.path,
          type: path.type,
          unresolved: Library.count_inbox_files(library_path_id: path.id)
        }
      end)

    {:ok,
     socket
     |> assign(:page_title, "Review")
     |> assign(:library_paths, library_paths)
     |> assign(:selected_library_path_id, default_library_path_id(library_paths))
     |> assign(:collapsed_seasons, MapSet.new())
     |> assign(:batch_selected_ids, MapSet.new())
     |> assign(:batch_search_query, "")
     |> assign(:batch_search_results, [])
     |> assign(:batch_selected_match, nil)
     |> assign(:batch_season_value, "")
     |> assign(:group_file_ids, MapSet.new())
     |> assign(:actionable_file_ids, MapSet.new())
     |> assign(:editing_file_id, nil)
     |> assign(:editing_file_name, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_results, [])
     |> assign(:rematching_series_key, nil)
     |> assign(:series_search_results, [])
     |> load_group()}
  end

  @impl true
  def handle_event("select_library", %{"library_path_id" => id}, socket) do
    if Enum.any?(socket.assigns.library_paths, &(&1.id == id)) do
      {:noreply, socket |> assign(:selected_library_path_id, id) |> load_group()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("approve_file", %{"id" => media_file_id}, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      media_file = Library.get_media_file!(media_file_id)

      case Library.list_match_candidates(media_file_id) do
        [%{provider_id: provider_id} = candidate | _] when not is_nil(provider_id) ->
          match = candidate_to_match(candidate)

          case FileIngest.ingest(media_file, match, policy: :create_items, threshold: 0.0) do
            {:linked, _media_item} ->
              {:noreply,
               socket
               |> forget_file(media_file_id)
               |> put_flash(:info, "Added #{candidate.title}")
               |> load_group()}

            _ ->
              {:noreply, put_flash(socket, :error, "Could not add #{candidate.title}")}
          end

        _ ->
          {:noreply, put_flash(socket, :error, "That file has no match to add yet.")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("edit_file", %{"id" => id}, socket) do
    media_file = Library.get_media_file!(id, preload: [:library_path])
    candidate = List.first(Library.list_match_candidates(id))

    form = %{
      "title" => (candidate && candidate.title) || "",
      "provider_id" => (candidate && candidate.provider_id) || "",
      "type" => media_type(candidate && candidate.media_type),
      "season" => season_string(candidate),
      "episodes" => episodes_string(candidate)
    }

    {:noreply,
     socket
     |> assign(:editing_file_id, id)
     |> assign(:editing_file_name, MediaFile.display_name(media_file))
     |> assign(:edit_form, form)
     |> assign(:search_results, [])}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_file_id, nil)
     |> assign(:editing_file_name, nil)
     |> assign(:edit_form, nil)
     |> assign(:search_results, [])}
  end

  def handle_event("search_metadata", %{"edit_form" => %{"title" => query}}, socket) do
    {:noreply, assign(socket, :search_results, search_metadata(query))}
  end

  def handle_event("select_search_result", params, socket) do
    form =
      socket.assigns.edit_form
      |> Map.put("title", params["title"])
      |> Map.put("provider_id", params["provider_id"])
      |> Map.put("type", params["type"])

    {:noreply, socket |> assign(:edit_form, form) |> assign(:search_results, [])}
  end

  def handle_event("save_edit", %{"edit_form" => params}, socket) do
    with :ok <- Authorization.authorize_import_media(socket),
         id when is_binary(id) <- socket.assigns.editing_file_id do
      attrs = %{
        media_file_id: id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: params["provider_id"],
        title: params["title"],
        media_type: media_type(params["type"]),
        confidence: 1.0,
        parsed_info: %{
          "season" => parse_int(params["season"]),
          "episodes" => parse_episode_list(params["episodes"])
        },
        attempts: 0,
        last_error: nil
      }

      case Library.upsert_match_candidate(attrs) do
        {:ok, _candidate} ->
          {:noreply,
           socket
           |> assign(:editing_file_id, nil)
           |> assign(:editing_file_name, nil)
           |> assign(:edit_form, nil)
           |> put_flash(:info, "Match updated")
           |> load_group()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "That match could not be saved.")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("batch_toggle_file", %{"id" => id}, socket) do
    if id in socket.assigns.group_file_ids do
      selected = socket.assigns.batch_selected_ids

      selected =
        if MapSet.member?(selected, id),
          do: MapSet.delete(selected, id),
          else: MapSet.put(selected, id)

      {:noreply, assign(socket, :batch_selected_ids, selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("batch_select_all", _params, socket) do
    {:noreply, assign(socket, :batch_selected_ids, socket.assigns.actionable_file_ids)}
  end

  def handle_event("batch_deselect_all", _params, socket) do
    {:noreply, assign(socket, :batch_selected_ids, MapSet.new())}
  end

  def handle_event("batch_search", %{"value" => query}, socket) do
    {:noreply,
     socket
     |> assign(:batch_search_query, query)
     |> assign(:batch_search_results, search_metadata(query))}
  end

  def handle_event("batch_select_search_result", params, socket) do
    match = %{
      title: params["title"],
      provider_id: params["provider_id"],
      year: if(params["year"] not in [nil, ""], do: params["year"]),
      type: media_type(params["type"])
    }

    {:noreply,
     socket
     |> assign(:batch_selected_match, match)
     |> assign(:batch_search_query, match.title)
     |> assign(:batch_search_results, [])}
  end

  def handle_event("batch_clear_match", _params, socket) do
    {:noreply,
     socket
     |> assign(:batch_selected_match, nil)
     |> assign(:batch_search_query, "")
     |> assign(:batch_search_results, [])}
  end

  def handle_event("batch_update_season", %{"value" => value}, socket) do
    {:noreply, assign(socket, :batch_season_value, value)}
  end

  def handle_event("batch_apply", _params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      selected_ids = MapSet.to_list(socket.assigns.batch_selected_ids)
      match = socket.assigns.batch_selected_match
      season = parse_int(socket.assigns.batch_season_value)

      if match == nil and season == nil do
        {:noreply,
         put_flash(
           socket,
           :error,
           "No changes to apply. Select a series/movie or enter a season number."
         )}
      else
        {:ok, %{updated: updated, failed: failed}} =
          Library.apply_batch_match(selected_ids, match, season)

        {:noreply,
         socket
         |> assign(:batch_selected_ids, MapSet.new())
         |> assign(:batch_search_query, "")
         |> assign(:batch_search_results, [])
         |> assign(:batch_selected_match, nil)
         |> assign(:batch_season_value, "")
         |> put_flash(batch_flash_kind(failed), batch_flash_message(updated, failed))
         |> load_group()}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_season_collapse", %{"season_id" => id}, socket) do
    collapsed = socket.assigns.collapsed_seasons

    collapsed =
      if MapSet.member?(collapsed, id),
        do: MapSet.delete(collapsed, id),
        else: MapSet.put(collapsed, id)

    {:noreply, assign(socket, :collapsed_seasons, collapsed)}
  end

  def handle_event("toggle_season_selection", %{"ids" => ids}, socket) do
    # Guard against a crafted or runaway payload; 64 KB is generous for any
    # real season but still finite. Drop the event silently rather than
    # splitting an arbitrarily long string in the LiveView process.
    if String.length(ids) > 65_536 do
      {:noreply, socket}
    else
      episode_ids = ids |> String.split(",") |> Enum.filter(&(&1 != ""))
      valid_ids = MapSet.new(episode_ids) |> MapSet.intersection(socket.assigns.group_file_ids)

      selected = socket.assigns.batch_selected_ids

      selected =
        if MapSet.subset?(valid_ids, selected),
          do: MapSet.difference(selected, valid_ids),
          else: MapSet.union(selected, valid_ids)

      {:noreply, assign(socket, :batch_selected_ids, selected)}
    end
  end

  def handle_event("edit_series_rematch", %{"series_key" => key}, socket) do
    {:noreply,
     socket |> assign(:rematching_series_key, key) |> assign(:series_search_results, [])}
  end

  def handle_event("cancel_series_rematch", _params, socket) do
    {:noreply,
     socket |> assign(:rematching_series_key, nil) |> assign(:series_search_results, [])}
  end

  def handle_event("search_series_rematch", %{"query" => query}, socket) do
    {:noreply, assign(socket, :series_search_results, search_metadata(query))}
  end

  def handle_event("select_series_rematch", params, socket) do
    with :ok <- Authorization.authorize_import_media(socket) do
      key = socket.assigns.rematching_series_key
      series = Enum.find(socket.assigns.group.series, &(FileGrouper.series_key(&1) == key))

      if series do
        episode_ids =
          for season <- series.seasons, episode <- season.episodes, do: episode.file.media_file.id

        match = %{
          title: params["title"],
          provider_id: params["provider_id"],
          type: "tv_show"
        }

        {:ok, %{updated: updated, failed: failed}} =
          Library.apply_batch_match(episode_ids, match, nil)

        {:noreply,
         socket
         |> assign(:rematching_series_key, nil)
         |> assign(:series_search_results, [])
         |> put_flash(batch_flash_kind(failed), batch_flash_message(updated, failed))
         |> load_group()}
      else
        # The series was approved (or removed) from another session between
        # when this user opened the rematch UI and when they clicked a result.
        # Reload so the stale group entry disappears rather than leaving
        # the user staring at a search result that no longer applies.
        {:noreply,
         socket
         |> assign(:rematching_series_key, nil)
         |> assign(:series_search_results, [])
         |> put_flash(
           :info,
           "That series is no longer in the queue — the list has been refreshed."
         )
         |> load_group()}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp candidate_to_match(candidate) do
    %{
      provider_id: candidate.provider_id,
      provider_type: provider_type_atom(candidate.provider_type),
      title: candidate.title,
      year: candidate.year,
      match_confidence: candidate.confidence || 1.0,
      metadata: %{},
      manually_edited: true,
      parsed_info: restore_parsed_info(candidate)
    }
  end

  defp restore_parsed_info(candidate) do
    parsed = candidate.parsed_info || %{}

    %{
      type: media_type_atom(candidate.media_type),
      season: Map.get(parsed, "season"),
      episodes: Map.get(parsed, "episodes") || []
    }
  end

  defp provider_type_atom("tvdb"), do: :tvdb
  defp provider_type_atom(_), do: :tmdb

  defp media_type_atom("tv_show"), do: :tv_show
  defp media_type_atom(_), do: :movie

  defp media_type(type) when type in @media_types, do: type
  defp media_type(_), do: @default_media_type

  defp forget_file(socket, media_file_id) do
    socket =
      if socket.assigns.editing_file_id == media_file_id do
        socket
        |> assign(:editing_file_id, nil)
        |> assign(:editing_file_name, nil)
        |> assign(:edit_form, nil)
      else
        socket
      end

    assign(
      socket,
      :batch_selected_ids,
      MapSet.delete(socket.assigns.batch_selected_ids, media_file_id)
    )
  end

  defp batch_flash_kind(0), do: :info
  defp batch_flash_kind(_failed), do: :error

  defp batch_flash_message(updated, 0), do: "Batch edit applied to #{updated} file(s)"

  defp batch_flash_message(updated, failed) do
    "Batch edit applied to #{updated} file(s). #{failed} could not be updated, " <>
      "most likely because they are no longer in the library."
  end

  defp season_string(nil), do: ""

  defp season_string(candidate) do
    case Map.get(candidate.parsed_info || %{}, "season") do
      nil -> ""
      season -> to_string(season)
    end
  end

  defp episodes_string(nil), do: ""

  defp episodes_string(candidate) do
    (candidate.parsed_info || %{})
    |> Map.get("episodes", [])
    |> Enum.join(", ")
  end

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp parse_episode_list(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_int/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_episode_list(_), do: []

  defp search_metadata(query) do
    if String.length(String.trim(query)) < 2 do
      []
    else
      config = Metadata.default_relay_config()

      movie =
        case Metadata.search(config, query, media_type: :movie) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "movie"))
          _ -> []
        end

      tv =
        case Metadata.search(config, query, media_type: :tv_show) do
          {:ok, results} -> Enum.map(results, &Map.put(&1, :media_type, "tv_show"))
          _ -> []
        end

      Enum.take(movie ++ tv, 10)
    end
  end

  defp default_library_path_id([]), do: nil

  defp default_library_path_id(paths) do
    paths |> Enum.max_by(& &1.unresolved) |> Map.fetch!(:id)
  end

  defp load_group(%{assigns: %{selected_library_path_id: nil}} = socket) do
    socket
    |> assign(:group, %{series: [], movies: [], unmatched: [], wrong_library: []})
    |> assign(:group_file_ids, MapSet.new())
    |> assign(:actionable_file_ids, MapSet.new())
  end

  defp load_group(socket) do
    group = Library.group_inbox_files(socket.assigns.selected_library_path_id)
    {file_ids, actionable_ids} = extract_group_file_ids(group)

    socket
    |> assign(:group, group)
    |> assign(:group_file_ids, file_ids)
    |> assign(:actionable_file_ids, actionable_ids)
  end

  defp extract_group_file_ids(%{
         series: series,
         movies: movies,
         unmatched: unmatched,
         wrong_library: wrong
       }) do
    series_ids =
      Enum.flat_map(series, fn s ->
        Enum.flat_map(s.seasons, fn season ->
          Enum.map(season.episodes, & &1.file.media_file.id)
        end)
      end)

    movie_ids = Enum.map(movies, & &1.file.media_file.id)
    unmatched_ids = Enum.map(unmatched, & &1.file.media_file.id)
    wrong_ids = Enum.map(wrong, & &1.file.media_file.id)

    all_ids = MapSet.new(series_ids ++ movie_ids ++ unmatched_ids ++ wrong_ids)
    # wrong_library files need to be moved to another library, not re-matched,
    # so they are excluded from the actionable set used by batch_select_all.
    actionable_ids = MapSet.new(series_ids ++ movie_ids ++ unmatched_ids)

    {all_ids, actionable_ids}
  end

  defp total_unresolved(%{
         series: series,
         movies: movies,
         unmatched: unmatched,
         wrong_library: wrong
       }) do
    series_count =
      Enum.reduce(series, 0, fn s, acc ->
        acc + Enum.reduce(s.seasons, 0, fn season, a2 -> a2 + length(season.episodes) end)
      end)

    series_count + length(movies) + length(unmatched) + length(wrong)
  end
end
