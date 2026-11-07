defmodule Mydia.Demo.Library do
  @moduledoc """
  Seeds a demo library (movies, shows, episodes, files and watch progress) for
  website screenshots, from a local list of TMDB ids.

  The list is an untracked file, `.demo-titles.local` at the repository root by
  default, so no title is ever committed. One entry per line:

      movie 12345
      tv 67890   # comments may follow, or fill a line

  Every entry is fetched through the metadata relay, the same way the add-media
  flow fetches it (`Mydia.Metadata.fetch_by_ref/3` and
  `Mydia.Media.Add.build_media_item_attrs/3`), so items carry the real
  `tmdb_id`, poster and backdrop. Shows also get their real seasons and
  episodes. All network work happens before the transaction: a failed fetch
  returns `{:error, {:fetch_failed, entry, reason}}` and writes nothing.

  `seed/1` refuses a database that already holds media. Every item and episode
  is unmonitored, so scheduled jobs leave them alone. Media files are database
  rows only: one per movie, and one per aired episode, hanging off the episode
  with a NULL `media_item_id`.
  """

  import Ecto.Query

  alias Mydia.Accounts.{Scope, User}
  alias Mydia.Library.MediaFiles
  alias Mydia.Media
  alias Mydia.Media.{Add, Episode, EpisodeSync, MediaItem}
  alias Mydia.Metadata
  alias Mydia.Playback
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPaths

  @default_titles ".demo-titles.local"
  @episode_seconds 2700
  @movie_seconds 6600
  @fetch_concurrency 4

  @type entry :: {:movie | :tv, pos_integer()}

  @doc """
  Parses a title list: `movie <tmdb_id>` or `tv <tmdb_id>` per line, `#`
  starting a comment, blank lines ignored.
  """
  @spec parse_titles(String.t()) ::
          {:ok, [entry()]} | {:error, {:invalid_line, pos_integer(), String.t()} | :no_titles}
  def parse_titles(contents) do
    contents
    |> String.split(~r/\R/)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case parse_line(line) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        :error -> {:halt, {:error, {:invalid_line, number, line}}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_titles}
      {:ok, entries} -> {:ok, entries |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp parse_line(line) do
    case line |> String.split("#", parts: 2) |> hd() |> String.split() do
      [] -> :skip
      ["movie", id] -> parse_id(:movie, id)
      ["tv", id] -> parse_id(:tv, id)
      _ -> :error
    end
  end

  defp parse_id(kind, id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, {kind, n}}
      _ -> :error
    end
  end

  @doc """
  Seeds the demo library. See the module doc.

  ## Options

    * `:titles` - path of the title list (default `.demo-titles.local` under
      the current directory)
    * `:user` - the user who gets watch progress (default the first admin)
  """
  @spec seed(keyword()) ::
          {:ok,
           %{movies: non_neg_integer(), shows: non_neg_integer(), episodes: non_neg_integer()}}
          | {:error,
             :not_empty
             | :no_admin_user
             | :no_titles
             | {:titles_file, String.t(), File.posix()}
             | {:invalid_line, pos_integer(), String.t()}
             | {:fetch_failed, entry(), term()}
             | term()}
  def seed(opts \\ []) do
    path = Keyword.get_lazy(opts, :titles, fn -> Path.expand(@default_titles, File.cwd!()) end)

    with :ok <- check_empty(),
         {:ok, user} <- resolve_user(Keyword.get(opts, :user)),
         {:ok, entries} <- read_titles(path),
         {:ok, fetched} <- fetch_all(entries) do
      write(user, fetched)
    end
  end

  defp check_empty do
    if Repo.exists?(MediaItem), do: {:error, :not_empty}, else: :ok
  end

  defp resolve_user(%User{} = user), do: {:ok, user}

  defp resolve_user(nil) do
    case Repo.one(
           from u in User, where: u.role == "admin", order_by: [asc: u.inserted_at], limit: 1
         ) do
      nil -> {:error, :no_admin_user}
      user -> {:ok, user}
    end
  end

  defp read_titles(path) do
    case File.read(path) do
      {:ok, contents} -> parse_titles(contents)
      {:error, reason} -> {:error, {:titles_file, path, reason}}
    end
  end

  ## Fetching (no database writes)

  defp fetch_all(entries) do
    config = Metadata.default_relay_config()

    entries
    |> Task.async_stream(&fetch_entry(&1, config),
      max_concurrency: @fetch_concurrency,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, fetched}}, {:ok, acc} -> {:cont, {:ok, [fetched | acc]}}
      {:ok, {:error, _} = error}, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, fetched} -> {:ok, Enum.reverse(fetched)}
      error -> error
    end
  end

  defp fetch_entry({kind, id} = entry, config) do
    media_type = media_type(kind)
    ref = {:tmdb, id}

    with {:ok, metadata} <-
           Metadata.fetch_by_ref(config, ref,
             media_type: media_type,
             append_to_response: Metadata.default_append_to_response(media_type)
           ),
         {:ok, seasons} <- fetch_seasons(kind, metadata, ref, config) do
      # metadata_source is recorded for shows only; build_media_item_attrs
      # drops it for movies. Seasons were fetched from TMDB, so that is the
      # provenance that keeps a later refresh on the same episode numbering.
      attrs =
        Add.build_media_item_attrs(metadata, media_type,
          tmdb_id: id,
          metadata_source: :tmdb,
          monitored: false
        )

      {:ok, %{entry: entry, attrs: attrs, seasons: seasons}}
    else
      {:error, reason} -> {:error, {:fetch_failed, entry, reason}}
    end
  end

  defp fetch_seasons(:movie, _metadata, _ref, _config), do: {:ok, []}

  defp fetch_seasons(:tv, metadata, ref, config) do
    (metadata.seasons || [])
    |> Enum.map(& &1.season_number)
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.reduce_while({:ok, []}, fn number, {:ok, acc} ->
      case Metadata.fetch_season_by_ref(config, ref, number) do
        {:ok, season} -> {:cont, {:ok, [season | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, seasons} -> {:ok, Enum.reverse(seasons)}
      error -> error
    end
  end

  defp media_type(:movie), do: :movie
  defp media_type(:tv), do: :tv_show

  ## Writing

  defp write(user, fetched) do
    Repo.transaction(fn ->
      {:ok, movies_path} =
        LibraryPaths.create_library_path(%{path: "/demo/movies", type: :movies})

      {:ok, tv_path} = LibraryPaths.create_library_path(%{path: "/demo/tv", type: :series})

      {movie_entries, show_entries} = Enum.split_with(fetched, &match?({:movie, _}, &1.entry))

      movies = movie_entries |> Enum.with_index() |> Enum.map(&seed_movie(&1, movies_path))
      shows = show_entries |> Enum.with_index() |> Enum.map(&seed_show(&1, tv_path))

      seed_progress(user, movies, shows)

      %{
        movies: length(movies),
        shows: length(shows),
        episodes: shows |> Enum.map(&length(&1.episodes)) |> Enum.sum()
      }
    end)
  end

  defp seed_movie({%{attrs: attrs}, index}, library_path) do
    item = create_item!(attrs, library_path)
    name = folder_name(item)

    create_file!(library_path, "#{name}/#{name}.mkv", %{media_item_id: item.id}, index)

    runtime = item.metadata && item.metadata.runtime

    %{
      item: item,
      seconds: if(is_integer(runtime) and runtime > 0, do: runtime * 60, else: @movie_seconds)
    }
  end

  defp seed_show({%{attrs: attrs, seasons: seasons}, index}, library_path) do
    item = create_item!(attrs, library_path)

    for season <- seasons do
      {:ok, _count} = EpisodeSync.upsert_episodes_from_season(item, season, monitor_new?: false)
    end

    today = Date.utc_today()

    episodes =
      Repo.all(
        from e in Episode,
          where: e.media_item_id == ^item.id,
          order_by: [asc: e.season_number, asc: e.episode_number]
      )

    aired = Enum.filter(episodes, &aired?(&1, today))
    name = folder_name(item)

    aired
    |> Enum.with_index()
    |> Enum.each(fn {episode, pos} ->
      season = pad(episode.season_number)
      number = pad(episode.episode_number)

      # TV files carry episode_id only; the show hangs off the episode.
      create_file!(
        library_path,
        "#{name}/Season #{season}/#{name} - S#{season}E#{number}.mkv",
        %{episode_id: episode.id},
        index + pos
      )
    end)

    %{item: item, episodes: episodes, aired: aired}
  end

  defp aired?(%Episode{air_date: %Date{} = date}, today), do: Date.compare(date, today) != :gt
  defp aired?(_episode, _today), do: false

  defp create_item!(attrs, library_path) do
    attrs = Map.put(attrs, :library_path_id, library_path.id)

    {:ok, item} = Media.create_media_item(Scope.system(), attrs, skip_episode_refresh: true)
    item
  end

  defp folder_name(%MediaItem{title: title, year: nil}), do: title
  defp folder_name(%MediaItem{title: title, year: year}), do: "#{title} (#{year})"

  defp create_file!(library_path, relative_path, parent, seed) do
    attrs =
      Map.merge(parent, %{
        library_path_id: library_path.id,
        relative_path: relative_path,
        size: 1_500_000_000 + :erlang.phash2({relative_path, seed}, 3_000_000_000),
        resolution: "1080p",
        codec: "h264",
        audio_codec: "aac"
      })

    {:ok, file} = MediaFiles.create_media_file(attrs)
    file
  end

  # Two movies part-way through, plus, for the first two shows with enough
  # aired episodes, a run of watched episodes followed by one in progress.
  defp seed_progress(user, movies, shows) do
    for {%{item: item, seconds: seconds}, fraction} <- Enum.zip(movies, [0.4, 0.15]) do
      save!(user, [media_item_id: item.id], round(seconds * fraction), seconds)
    end

    shows
    |> Enum.map(&latest_aired_season/1)
    |> Enum.filter(&(length(&1) >= 2))
    |> Enum.zip([3, 2])
    |> Enum.each(fn {season_episodes, target} ->
      current = min(target, length(season_episodes) - 1)

      season_episodes
      |> Enum.take(current + 1)
      |> Enum.with_index()
      |> Enum.each(fn
        {episode, ^current} ->
          seconds = episode_seconds(episode)
          save!(user, [episode_id: episode.id], round(seconds * 0.45), seconds)

        {episode, _earlier} ->
          seconds = episode_seconds(episode)
          save!(user, [episode_id: episode.id], seconds, seconds)
      end)
    end)

    :ok
  end

  # The aired episodes of the newest season that has any, in order.
  defp latest_aired_season(%{aired: []}), do: []

  defp latest_aired_season(%{aired: aired}) do
    season = aired |> Enum.map(& &1.season_number) |> Enum.max()
    Enum.filter(aired, &(&1.season_number == season))
  end

  defp episode_seconds(%Episode{metadata: %{runtime: runtime}})
       when is_integer(runtime) and runtime > 0,
       do: runtime * 60

  defp episode_seconds(%Episode{metadata: %{"runtime" => runtime}})
       when is_integer(runtime) and runtime > 0,
       do: runtime * 60

  defp episode_seconds(_episode), do: @episode_seconds

  defp save!(user, content_id, position, duration) do
    {:ok, _} =
      Playback.save_progress(user.id, content_id, %{
        position_seconds: position,
        duration_seconds: duration
      })
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
