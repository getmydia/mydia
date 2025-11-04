defmodule MydiaWeb.MediaLive.Show do
  use MydiaWeb, :live_view
  alias Mydia.Media
  alias Mydia.Settings

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    media_item = load_media_item(id)
    quality_profiles = Settings.list_quality_profiles()

    {:ok,
     socket
     |> assign(:media_item, media_item)
     |> assign(:page_title, media_item.title)
     |> assign(:show_edit_modal, false)
     |> assign(:show_delete_confirm, false)
     |> assign(:quality_profiles, quality_profiles)
     |> assign(:edit_form, nil)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_monitored", _params, socket) do
    media_item = socket.assigns.media_item
    {:ok, updated_item} = Media.update_media_item(media_item, %{monitored: !media_item.monitored})

    {:noreply,
     socket
     |> assign(:media_item, updated_item)
     |> put_flash(
       :info,
       "Monitoring #{if updated_item.monitored, do: "enabled", else: "disabled"}"
     )}
  end

  def handle_event("manual_search", _params, socket) do
    media_item = socket.assigns.media_item

    # Build search query from media item
    search_query =
      case media_item.type do
        "movie" ->
          # For movies, search with title and year
          if media_item.year do
            "#{media_item.title} #{media_item.year}"
          else
            media_item.title
          end

        "tv_show" ->
          # For TV shows, just use the title
          media_item.title
      end

    {:noreply, push_navigate(socket, to: ~p"/search?#{%{q: search_query}}")}
  end

  def handle_event("show_edit_modal", _params, socket) do
    media_item = socket.assigns.media_item
    changeset = Media.change_media_item(media_item)

    {:noreply,
     socket
     |> assign(:show_edit_modal, true)
     |> assign(:edit_form, to_form(changeset))}
  end

  def handle_event("hide_edit_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_modal, false)
     |> assign(:edit_form, nil)}
  end

  def handle_event("validate_edit", %{"media_item" => media_params}, socket) do
    changeset =
      socket.assigns.media_item
      |> Media.change_media_item(media_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_form, to_form(changeset))}
  end

  def handle_event("save_edit", %{"media_item" => media_params}, socket) do
    media_item = socket.assigns.media_item

    case Media.update_media_item(media_item, media_params) do
      {:ok, updated_item} ->
        {:noreply,
         socket
         |> assign(:media_item, updated_item)
         |> assign(:show_edit_modal, false)
         |> assign(:edit_form, nil)
         |> put_flash(:info, "Settings updated successfully")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  def handle_event("show_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, true)}
  end

  def handle_event("hide_delete_confirm", _params, socket) do
    {:noreply, assign(socket, :show_delete_confirm, false)}
  end

  def handle_event("delete_media", _params, socket) do
    media_item = socket.assigns.media_item

    case Media.delete_media_item(media_item) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{media_item.title} deleted successfully")
         |> push_navigate(to: ~p"/media")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete #{media_item.title}")
         |> assign(:show_delete_confirm, false)}
    end
  end

  def handle_event("toggle_episode_monitored", %{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(episode_id)
    {:ok, _updated_episode} = Media.update_episode(episode, %{monitored: !episode.monitored})

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(
       :info,
       "Episode monitoring #{if episode.monitored, do: "disabled", else: "enabled"}"
     )}
  end

  def handle_event("search_episode", %{"episode-id" => episode_id}, socket) do
    episode = Media.get_episode!(episode_id, preload: [:media_item])
    media_item = episode.media_item

    # Build search query for the episode
    # Format: "Show Title S01E02" or "Show Title 1x02"
    search_query =
      "#{media_item.title} S#{String.pad_leading(to_string(episode.season_number), 2, "0")}E#{String.pad_leading(to_string(episode.episode_number), 2, "0")}"

    {:noreply, push_navigate(socket, to: ~p"/search?#{%{q: search_query}}")}
  end

  @impl true
  def handle_info({:download_created, download}, socket) do
    if download_for_media?(download, socket.assigns.media_item) do
      {:noreply, assign(socket, :media_item, load_media_item(socket.assigns.media_item.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:download_updated, download}, socket) do
    if download_for_media?(download, socket.assigns.media_item) do
      {:noreply, assign(socket, :media_item, load_media_item(socket.assigns.media_item.id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_media_item(id) do
    preload_list = build_preload_list()

    Media.get_media_item!(id, preload: preload_list)
  end

  defp build_preload_list do
    [
      quality_profile: [],
      episodes: [:media_files, downloads: :media_item],
      media_files: [],
      downloads: []
    ]
  end

  defp download_for_media?(download, media_item) do
    download.media_item_id == media_item.id or
      (download.episode_id &&
         Enum.any?(media_item.episodes, fn ep -> ep.id == download.episode_id end))
  end

  defp get_poster_url(media_item) do
    case media_item.metadata do
      %{"poster_path" => path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/w500#{path}"

      _ ->
        "/images/no-poster.jpg"
    end
  end

  defp get_backdrop_url(media_item) do
    case media_item.metadata do
      %{"backdrop_path" => path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/original#{path}"

      _ ->
        nil
    end
  end

  defp get_overview(media_item) do
    case media_item.metadata do
      %{"overview" => overview} when is_binary(overview) and overview != "" ->
        overview

      _ ->
        "No overview available."
    end
  end

  defp get_rating(media_item) do
    case media_item.metadata do
      %{"vote_average" => rating} when is_number(rating) ->
        Float.round(rating, 1)

      _ ->
        nil
    end
  end

  defp get_runtime(media_item) do
    case media_item.metadata do
      %{"runtime" => runtime} when is_integer(runtime) and runtime > 0 ->
        hours = div(runtime, 60)
        minutes = rem(runtime, 60)

        cond do
          hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
          hours > 0 -> "#{hours}h"
          true -> "#{minutes}m"
        end

      _ ->
        nil
    end
  end

  defp get_genres(media_item) do
    case media_item.metadata do
      %{"genres" => genres} when is_list(genres) ->
        Enum.map(genres, fn
          %{"name" => name} -> name
          name when is_binary(name) -> name
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp get_cast(media_item, limit \\ 6) do
    case media_item.metadata do
      %{"credits" => %{"cast" => cast}} when is_list(cast) ->
        cast
        |> Enum.take(limit)
        |> Enum.map(fn actor ->
          %{
            name: actor["name"],
            character: actor["character"],
            profile_path: actor["profile_path"]
          }
        end)

      _ ->
        []
    end
  end

  defp get_crew(media_item) do
    case media_item.metadata do
      %{"credits" => %{"crew" => crew}} when is_list(crew) ->
        # Get key crew members (directors, writers, producers)
        crew
        |> Enum.filter(fn member ->
          member["job"] in ["Director", "Writer", "Screenplay", "Executive Producer", "Producer"]
        end)
        |> Enum.uniq_by(fn member -> {member["name"], member["job"]} end)
        |> Enum.take(6)
        |> Enum.map(fn member ->
          %{name: member["name"], job: member["job"]}
        end)

      _ ->
        []
    end
  end

  defp get_profile_image_url(nil), do: nil

  defp get_profile_image_url(path) when is_binary(path) do
    "https://image.tmdb.org/t/p/w185#{path}"
  end

  defp format_file_size(nil), do: "N/A"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_date(nil), do: "N/A"

  defp format_date(%Date{} = date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp group_episodes_by_season(episodes) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.sort_by(fn {season, _} -> season end)
  end

  defp get_episode_quality_badge(episode) do
    case episode.media_files do
      [] ->
        nil

      files ->
        files
        |> Enum.map(& &1.resolution)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(:desc)
        |> List.first()
    end
  end

  defp get_download_status(media_item) do
    active_downloads =
      media_item.downloads
      |> Enum.filter(fn d -> d.status in ["pending", "downloading"] end)

    case active_downloads do
      [] -> nil
      [download | _] -> download
    end
  end

  defp format_download_status("pending"), do: "Queued"
  defp format_download_status("downloading"), do: "Downloading"
  defp format_download_status("completed"), do: "Completed"
  defp format_download_status("failed"), do: "Failed"
  defp format_download_status("cancelled"), do: "Cancelled"
  defp format_download_status(_), do: "Unknown"
end
