defmodule MydiaWeb.PlaybackLive.Show do
  use MydiaWeb, :live_view
  alias Mydia.Media

  @impl true
  def mount(%{"type" => type, "id" => id}, _session, socket) when type in ["movie", "episode"] do
    scope = socket.assigns.current_scope

    # Load content based on type
    {content, title} = load_content(scope, type, id)

    # Get next episode info if this is an episode
    next_episode_info = get_next_episode_info(scope, type, content)

    # Get intro/credits timestamps from metadata
    {intro_start, intro_end, credits_start} = get_skip_timestamps(type, content)

    # Get known duration from media file metadata (for HLS streams)
    known_duration = get_known_duration(content)

    {:ok,
     socket
     |> assign(:content_type, type)
     |> assign(:content_id, id)
     |> assign(:content, content)
     |> assign(:next_episode, next_episode_info)
     |> assign(:intro_start, intro_start)
     |> assign(:intro_end, intro_end)
     |> assign(:credits_start, credits_start)
     |> assign(:known_duration, known_duration)
     |> assign(:page_title, "Playing: #{title}")}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_content(scope, "movie", media_item_id) do
    media_item = Media.get_media_item!(scope, media_item_id, preload: [:media_files])
    {media_item, media_item.title}
  end

  defp load_content(scope, "episode", episode_id) do
    episode = Media.get_episode!(scope, episode_id, preload: [:media_item, :media_files])
    title = "#{episode.media_item.title} - S#{episode.season_number}E#{episode.episode_number}"
    {episode, title}
  end

  defp get_back_url("movie", media_item), do: ~p"/media/#{media_item.id}"
  defp get_back_url("episode", episode), do: ~p"/media/#{episode.media_item_id}"

  defp get_title("movie", media_item), do: media_item.title

  defp get_title("episode", episode) do
    "#{episode.media_item.title}"
  end

  defp get_subtitle("movie", media_item) do
    parts = []
    parts = if media_item.year, do: [to_string(media_item.year) | parts], else: parts

    parts =
      case media_item.metadata do
        %{"runtime" => runtime} when is_integer(runtime) and runtime > 0 ->
          hours = div(runtime, 60)
          minutes = rem(runtime, 60)

          runtime_str =
            cond do
              hours > 0 and minutes > 0 -> "#{hours}h #{minutes}m"
              hours > 0 -> "#{hours}h"
              true -> "#{minutes}m"
            end

          [runtime_str | parts]

        _ ->
          parts
      end

    Enum.reverse(parts) |> Enum.join(" • ")
  end

  defp get_subtitle("episode", episode) do
    parts = ["S#{episode.season_number}E#{episode.episode_number}"]
    parts = if episode.title, do: [episode.title | parts], else: parts
    Enum.reverse(parts) |> Enum.join(" - ")
  end

  defp get_next_episode_info(_scope, "movie", _media_item), do: nil

  defp get_next_episode_info(scope, "episode", episode) do
    case Media.get_next_episode(scope, episode, preload: [:media_item]) do
      nil ->
        nil

      next_episode ->
        %{
          id: next_episode.id,
          title: next_episode.title,
          season_number: next_episode.season_number,
          episode_number: next_episode.episode_number,
          show_title: next_episode.media_item.title,
          poster_url: get_episode_poster(next_episode)
        }
    end
  end

  defp get_episode_poster(episode) do
    # Try to get episode-specific poster from metadata
    case episode.metadata do
      %{"poster_path" => path} when is_binary(path) ->
        ImageUrl.still_url(path)

      _ ->
        # Fall back to show poster
        case episode.media_item.metadata do
          %{"poster_path" => path} when is_binary(path) ->
            ImageUrl.still_url(path)

          _ ->
            nil
        end
    end
  end

  defp get_skip_timestamps("movie", _media_item), do: {nil, nil, nil}

  defp get_skip_timestamps("episode", episode) do
    case episode.metadata do
      %{"intro_start" => intro_start, "intro_end" => intro_end, "credits_start" => credits_start} ->
        {intro_start, intro_end, credits_start}

      %{"intro_start" => intro_start, "intro_end" => intro_end} ->
        {intro_start, intro_end, nil}

      %{"credits_start" => credits_start} ->
        {nil, nil, credits_start}

      _ ->
        {nil, nil, nil}
    end
  end

  # Extract known duration from media file metadata (populated by FFprobe during scanning)
  # This is used to display the correct duration immediately for HLS streams
  defp get_known_duration(content) do
    media_files = Map.get(content, :media_files, [])

    # Try to get duration from the first available media file
    Enum.find_value(media_files, fn media_file ->
      case media_file.metadata do
        %{duration: duration} when is_number(duration) and duration > 0 ->
          duration

        _ ->
          nil
      end
    end)
  end
end
