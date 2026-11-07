defmodule Mydia.Demo.Library do
  @moduledoc """
  Seeds an invented demo library (movies, shows, episodes, files, watch
  progress and artwork) for website screenshots. Every title is made up.

  `seed/1` refuses a database that already holds media. Artwork is rendered
  before any row is written, so a rendering failure leaves the database alone.
  """

  import Ecto.Query

  alias Mydia.Accounts.{Scope, User}
  alias Mydia.Demo.Artwork
  alias Mydia.Library.MediaFiles
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Playback
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPaths

  @movies [
    %{
      title: "Lanternfall Station",
      year: 2019,
      genres: ["Drama", "Mystery"],
      runtime: 112,
      overview:
        "A night clerk at a failing rail depot finds a lantern that glows only for lost travelers."
    },
    %{
      title: "The Quiet Orchard Job",
      year: 2021,
      genres: ["Comedy", "Crime"],
      runtime: 98,
      overview: "Three retired pickers plan one last heist: the county's prize apple harvest."
    },
    %{
      title: "Saltmarsh Radio",
      year: 2017,
      genres: ["Drama"],
      runtime: 104,
      overview: "A pirate radio host keeps a drowning village connected, one broadcast at a time."
    },
    %{
      title: "Midnight at Pellwick Pier",
      year: 2022,
      genres: ["Thriller", "Mystery"],
      runtime: 109,
      overview: "The last ferry never arrives, and the pier's regulars begin to disappear."
    },
    %{
      title: "A Kettle for Two Moons",
      year: 2020,
      genres: ["Fantasy", "Adventure"],
      runtime: 121,
      overview: "A tea merchant crosses a double-mooned desert to deliver one very old pot."
    },
    %{
      title: "Brannock Heights",
      year: 2018,
      genres: ["Drama", "Romance"],
      runtime: 116,
      overview: "Two neighbors on opposite floors fall in love through a broken intercom."
    },
    %{
      title: "Copper Weather",
      year: 2023,
      genres: ["Science Fiction"],
      runtime: 127,
      overview:
        "When the sky turns to metal, a weather forecaster is the only one still counting days."
    },
    %{
      title: "The Last Tram to Ovelle",
      year: 2016,
      genres: ["Drama", "History"],
      runtime: 133,
      overview:
        "On the final night of a city's tram line, a conductor carries one passenger's secret."
    },
    %{
      title: "Wintergreen Protocol",
      year: 2024,
      genres: ["Action", "Thriller"],
      runtime: 118,
      overview:
        "A greenhouse engineer is the only witness to a sabotage on a polar research base."
    },
    %{
      title: "Hollow Meridian",
      year: 2021,
      genres: ["Science Fiction", "Mystery"],
      runtime: 124,
      overview: "A survey crew drilling at the equator breaks into a room that should not exist."
    },
    %{
      title: "Marrow and Thistle",
      year: 2015,
      genres: ["Fantasy", "Drama"],
      runtime: 107,
      overview: "A bone-setter and a herbalist share a village and a long, quiet feud."
    },
    %{
      title: "Paper Lighthouse",
      year: 2022,
      genres: ["Animation", "Family"],
      runtime: 92,
      overview: "A girl folds a lighthouse from old maps, and ships begin to find their way home."
    },
    %{
      title: "Dunmore Drift",
      year: 2019,
      genres: ["Action", "Comedy"],
      runtime: 101,
      overview: "A getaway driver with a fear of highways has one night to cross the country."
    },
    %{
      title: "Thessaly Rides Alone",
      year: 2018,
      genres: ["Western"],
      runtime: 119,
      overview: "A surveyor rides into a boomtown that has quietly stopped drawing its own maps."
    },
    %{
      title: "Orbit of Small Things",
      year: 2023,
      genres: ["Science Fiction", "Family"],
      runtime: 96,
      overview: "A lonely station caretaker adopts every lost object that drifts past his window."
    },
    %{
      title: "Quillfeather Road",
      year: 2017,
      genres: ["Adventure", "Family"],
      runtime: 103,
      overview:
        "Two siblings follow a trail of feathers across a country that is slowly forgetting itself."
    },
    %{
      title: "Fennick's Wager",
      year: 2020,
      genres: ["Comedy", "Drama"],
      runtime: 110,
      overview: "A gambler bets his entire inheritance that he can stay honest for a month."
    },
    %{
      title: "Tidewrack",
      year: 2024,
      genres: ["Horror", "Thriller"],
      runtime: 99,
      overview: "What the tide leaves behind on a remote beach starts leaving again, on its own."
    },
    %{
      title: "The Velvet Quorum",
      year: 2016,
      genres: ["Comedy", "Drama"],
      runtime: 114,
      overview:
        "A theater committee must pick a new season before the roof, quite literally, falls in."
    },
    %{
      title: "Ashgrove After Dark",
      year: 2021,
      genres: ["Horror", "Mystery"],
      runtime: 105,
      overview:
        "A night-shift nurse notices the hospital's lights dim whenever someone is about to wake."
    }
  ]

  @shows [
    %{
      title: "Harbor Lights of Vennmoor",
      year: 2020,
      genres: ["Drama"],
      seasons: [8, 10],
      overview: "Keepers of a small island lighthouse trade stories with every ship that passes."
    },
    %{
      title: "The Brightwater Files",
      year: 2022,
      genres: ["Mystery", "Crime"],
      seasons: [8, 8, 6],
      overview: "A records clerk in a river town reopens cases the town agreed to forget."
    },
    %{
      title: "Nightshift at Corvane",
      year: 2021,
      genres: ["Comedy"],
      seasons: [10, 8],
      overview:
        "The overnight crew of a failing observatory keeps finding better things to watch."
    },
    %{
      title: "Tenders of the Gloam",
      year: 2023,
      genres: ["Fantasy", "Drama"],
      seasons: [8, 6],
      overview: "A guild of lamplighters keeps the dusk from lasting too long."
    },
    %{
      title: "Pebble Creek Pioneers",
      year: 2019,
      genres: ["Family", "Comedy"],
      seasons: [10],
      overview: "A cul-de-sac of unlikely neighbors builds a town from a single shared garden."
    },
    %{
      title: "The Understudy Hours",
      year: 2024,
      genres: ["Drama", "Comedy"],
      seasons: [6, 6],
      overview: "Every night, the backup cast of a failing theater has one chance to shine."
    },
    %{
      title: "Kestrel Court",
      year: 2018,
      genres: ["Drama", "Crime"],
      seasons: [8, 8, 8],
      overview: "A small-town magistrate and her clerk settle disputes the law never saw coming."
    },
    %{
      title: "Borrowed Summers",
      year: 2022,
      genres: ["Romance", "Drama"],
      seasons: [6],
      overview: "A swap of holiday homes between strangers turns into a decade of letters."
    }
  ]

  @episode_titles [
    "Arrivals",
    "Low Tide",
    "The Long Way Round",
    "Unsent Letters",
    "Borrowed Time",
    "Paper Boats",
    "Second Wind",
    "Quiet Hours",
    "Small Hours",
    "The Other Door",
    "Thin Ice",
    "Lost and Found",
    "Open Water",
    "A Fair Trade",
    "Last Light",
    "The Hollow Month"
  ]

  @provider_id_base 900_000
  @episode_seconds 2700

  @doc "Every movie and show title `seed/1` can write."
  @spec titles() :: [String.t()]
  def titles, do: Enum.map(@movies ++ @shows, & &1.title)

  @doc """
  Seeds the demo library. See the module doc.

  ## Options

    * `:art_dir` - where artwork is written (default `priv/static/images/demo`)
    * `:base_url` - prefix of the artwork URLs stored on items (default the endpoint URL)
    * `:renderer` - SVG to PNG command (default `"rsvg-convert"`)
    * `:user` - the user who gets watch progress (default the first admin)
  """
  @spec seed(keyword()) ::
          {:ok,
           %{movies: non_neg_integer(), shows: non_neg_integer(), episodes: non_neg_integer()}}
          | {:error, :not_empty | :no_admin_user | {:renderer_missing, String.t()} | term()}
  def seed(opts \\ []) do
    art_dir =
      Keyword.get_lazy(opts, :art_dir, fn ->
        Application.app_dir(:mydia, "priv/static/images/demo")
      end)

    base_url = Keyword.get_lazy(opts, :base_url, fn -> MydiaWeb.Endpoint.url() end)
    renderer = Keyword.get(opts, :renderer, "rsvg-convert")

    with :ok <- check_renderer(renderer),
         :ok <- check_empty(),
         {:ok, user} <- resolve_user(Keyword.get(opts, :user)),
         {:ok, art} <- render_artwork(art_dir, base_url, renderer) do
      write(user, art)
    end
  end

  defp check_renderer(renderer) do
    found? =
      if Path.type(renderer) == :absolute,
        do: File.exists?(renderer),
        else: System.find_executable(renderer) != nil

    if found?, do: :ok, else: {:error, {:renderer_missing, renderer}}
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

  # Returns %{title => %{poster_path: url, backdrop_path: url}}.
  defp render_artwork(art_dir, base_url, renderer) do
    Enum.reduce_while(titles(), {:ok, %{}}, fn title, {:ok, acc} ->
      with {:ok, poster} <- Artwork.render(title, :poster, art_dir, renderer),
           {:ok, backdrop} <- Artwork.render(title, :backdrop, art_dir, renderer) do
        urls = %{
          poster_path: image_url(base_url, poster),
          backdrop_path: image_url(base_url, backdrop)
        }

        {:cont, {:ok, Map.put(acc, title, urls)}}
      else
        {:error, reason} -> {:halt, {:error, {:artwork_failed, title, reason}}}
      end
    end)
  end

  defp image_url(base_url, file),
    do: String.trim_trailing(base_url, "/") <> "/images/demo/" <> file

  defp write(user, art) do
    Repo.transaction(fn ->
      {:ok, movies_path} =
        LibraryPaths.create_library_path(%{path: "/demo/movies", type: :movies})

      {:ok, tv_path} = LibraryPaths.create_library_path(%{path: "/demo/tv", type: :series})

      movies =
        @movies
        |> Enum.with_index()
        |> Enum.map(fn {movie, index} -> seed_movie(movie, index, movies_path, art) end)

      shows =
        @shows
        |> Enum.with_index(length(@movies))
        |> Enum.map(fn {show, index} -> seed_show(show, index, tv_path, art) end)

      episodes = Enum.flat_map(shows, & &1.episodes)

      seed_progress(user, movies, shows)

      %{movies: length(movies), shows: length(shows), episodes: length(episodes)}
    end)
  end

  defp seed_movie(movie, index, library_path, art) do
    item = create_item!(movie, "movie", index, library_path, art, %{runtime: movie.runtime})

    relative = "#{movie.title} (#{movie.year})/#{movie.title} (#{movie.year}).mkv"
    create_file!(library_path, relative, %{media_item_id: item.id}, index)

    %{item: item, runtime: movie.runtime}
  end

  defp seed_show(show, index, library_path, art) do
    item = create_item!(show, "tv_show", index, library_path, art, %{status: "Returning Series"})
    today = Date.utc_today()

    slots =
      for {count, season_idx} <- Enum.with_index(show.seasons, 1),
          number <- 1..count,
          do: {season_idx, number}

    future_count = 1 + rem(index, 2)
    aired_count = length(slots) - future_count

    episodes =
      slots
      |> Enum.with_index()
      |> Enum.map(fn {{season, number}, pos} ->
        air_date =
          if pos < aired_count,
            do: Date.add(today, -7 * (aired_count - 1 - pos) - 1),
            else: Date.add(today, 1 + 3 * (pos - aired_count))

        {:ok, episode} =
          Media.create_episode(%{
            media_item_id: item.id,
            season_number: season,
            episode_number: number,
            title: episode_title(index, pos),
            air_date: air_date,
            monitored: true
          })

        if pos < aired_count do
          relative =
            "#{show.title}/Season #{pad(season)}/#{show.title} - S#{pad(season)}E#{pad(number)}.mkv"

          # TV files carry episode_id only; the show hangs off the episode.
          create_file!(library_path, relative, %{episode_id: episode.id}, index + pos)
        end

        episode
      end)

    %{item: item, episodes: episodes, aired: aired_count}
  end

  defp create_item!(entry, type, index, library_path, art, extra_metadata) do
    urls = Map.fetch!(art, entry.title)

    metadata =
      Map.merge(
        %{
          provider: :tmdb,
          provider_id: Integer.to_string(@provider_id_base + index),
          media_type: String.to_atom(type),
          title: entry.title,
          year: entry.year,
          overview: entry.overview,
          genres: entry.genres,
          poster_path: urls.poster_path,
          backdrop_path: urls.backdrop_path,
          vote_average: 6.0 + :erlang.phash2({entry.title, :vote}, 30) / 10
        },
        extra_metadata
      )

    attrs = %{
      type: type,
      title: entry.title,
      year: entry.year,
      tmdb_id: @provider_id_base + index,
      metadata_source: :tmdb,
      monitored: true,
      library_path_id: library_path.id,
      metadata: metadata
    }

    {:ok, item} = Media.create_media_item(Scope.system(), attrs, skip_episode_refresh: true)
    item
  end

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

  # Two movies part-way through, plus, for two shows, a run of watched episodes
  # followed by one in progress.
  defp seed_progress(user, movies, shows) do
    for {%{item: item, runtime: runtime}, fraction} <- Enum.zip(Enum.take(movies, 2), [0.4, 0.15]) do
      duration = runtime * 60
      save!(user, [media_item_id: item.id], round(duration * fraction), duration)
    end

    for {show, current} <- Enum.zip(Enum.take(shows, 2), [3, 2]) do
      show.episodes
      |> Enum.take(current + 1)
      |> Enum.with_index()
      |> Enum.each(fn
        {episode, ^current} ->
          save!(user, [episode_id: episode.id], round(@episode_seconds * 0.45), @episode_seconds)

        {episode, _earlier} ->
          save!(user, [episode_id: episode.id], @episode_seconds, @episode_seconds)
      end)
    end

    :ok
  end

  defp save!(user, content_id, position, duration) do
    {:ok, _} =
      Playback.save_progress(user.id, content_id, %{
        position_seconds: position,
        duration_seconds: duration
      })
  end

  defp episode_title(show_index, pos) do
    Enum.at(@episode_titles, rem(show_index * 5 + pos, length(@episode_titles)))
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
