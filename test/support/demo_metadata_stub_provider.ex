defmodule Mydia.DemoMetadataStubProvider do
  @moduledoc """
  In-memory metadata provider for the demo seed tests (`Mydia.Demo.Library`).

  Registered under `:metadata_relay` by `setup/0`, the same seam
  `Mydia.MetadataStub` uses, so the seed's real fetch path runs against it.
  Every title and id here is invented. Ids sit far above anything TMDB has
  issued.

  Episode air dates are relative to today, so each show has aired episodes
  (which get files) and upcoming ones (which fill the calendar).
  """

  @behaviour Mydia.Metadata.Provider

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider.{Error, Registry}
  alias Mydia.Metadata.Structs.{EpisodeData, MediaMetadata, SeasonData, SeasonInfo}

  @movies %{
    9_100_001 => "Ledger of Small Hours",
    9_100_002 => "Glassmoor Overture",
    9_100_003 => "Pilgrim Static"
  }

  # Per show, per season: {aired episodes, upcoming episodes}.
  @shows %{
    9_200_001 => {"Ferrylight", %{1 => {6, 0}, 2 => {3, 2}}},
    9_200_002 => {"The Orrery Clerks", %{1 => {4, 1}}}
  }

  @missing_id 9_999_999

  @doc "Registers the stub and restores the real providers on test exit."
  def setup do
    Registry.register(:metadata_relay, __MODULE__)
    Cache.clear()

    ExUnit.Callbacks.on_exit(fn ->
      Metadata.register_providers()
      Cache.clear()
    end)

    :ok
  end

  @doc "TMDB ids of the catalog movies, sorted."
  def movie_ids, do: @movies |> Map.keys() |> Enum.sort()

  @doc "TMDB ids of the catalog shows, sorted."
  def show_ids, do: @shows |> Map.keys() |> Enum.sort()

  @doc "Every catalog title."
  def titles, do: Map.values(@movies) ++ Enum.map(Map.values(@shows), &elem(&1, 0))

  @doc "An id whose fetch always fails."
  def missing_id, do: @missing_id

  @doc "Upcoming episodes across the catalog that air within the next 14 days."
  def upcoming_count do
    @shows
    |> Map.values()
    |> Enum.flat_map(fn {_title, seasons} -> Map.values(seasons) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  @impl true
  def test_connection(_config), do: {:ok, %{status: "ok"}}

  @impl true
  def search(_config, _query, _opts), do: {:ok, []}

  @impl true
  def fetch_images_by_ref(_config, ref, _opts), do: not_found(ref)

  @impl true
  def fetch_trending(_config, _opts), do: {:ok, []}

  @impl true
  def fetch_by_ref(_config, {:tmdb, id} = ref, opts) do
    case {Keyword.get(opts, :media_type, :movie), @movies[id], @shows[id]} do
      {:movie, title, _} when is_binary(title) -> {:ok, movie(id, title)}
      {:tv_show, _, {title, seasons}} -> {:ok, show(id, title, seasons)}
      _ -> not_found(ref)
    end
  end

  def fetch_by_ref(_config, ref, _opts), do: not_found(ref)

  @impl true
  def fetch_season_by_ref(_config, {:tmdb, id} = ref, number, _opts) do
    with {_title, seasons} <- @shows[id],
         {aired, upcoming} <- seasons[number] do
      {:ok, season(number, aired, upcoming)}
    else
      _ -> not_found(ref)
    end
  end

  def fetch_season_by_ref(_config, ref, _number, _opts), do: not_found(ref)

  defp not_found(ref), do: {:error, Error.not_found("Media not found: #{inspect(ref)}")}

  defp movie(id, title) do
    %MediaMetadata{
      provider_id: to_string(id),
      provider: :metadata_relay,
      media_type: :movie,
      id: id,
      title: title,
      original_title: title,
      year: 2024,
      release_date: ~D[2024-05-01],
      overview: "An invented demo movie.",
      runtime: 100,
      genres: ["Drama"],
      poster_path: "/demo-movie-#{id}-poster.jpg",
      backdrop_path: "/demo-movie-#{id}-backdrop.jpg",
      vote_average: 7.1
    }
  end

  defp show(id, title, seasons) do
    %MediaMetadata{
      provider_id: to_string(id),
      provider: :metadata_relay,
      media_type: :tv_show,
      id: id,
      title: title,
      original_title: title,
      year: 2023,
      first_air_date: ~D[2023-02-01],
      overview: "An invented demo series.",
      genres: ["Mystery"],
      poster_path: "/demo-show-#{id}-poster.jpg",
      backdrop_path: "/demo-show-#{id}-backdrop.jpg",
      vote_average: 7.8,
      number_of_seasons: map_size(seasons),
      # Specials (season 0) are listed but never fetched by the seed.
      seasons:
        [%SeasonInfo{season_number: 0, name: "Specials", episode_count: 1}] ++
          for {number, {aired, upcoming}} <- Enum.sort(seasons) do
            %SeasonInfo{
              season_number: number,
              name: "Season #{number}",
              episode_count: aired + upcoming
            }
          end
    }
  end

  # Aired episodes weekly up to two days ago; upcoming ones every few days
  # from tomorrow, all inside the next two weeks.
  defp season(number, aired, upcoming) do
    today = Date.utc_today()

    past =
      for n <- 1..aired//1,
          do: episode(number, n, Date.add(today, -2 - 7 * (aired - n) - 40 * (2 - number)))

    future =
      for k <- 1..upcoming//1, do: episode(number, aired + k, Date.add(today, 1 + 4 * (k - 1)))

    %SeasonData{
      season_number: number,
      name: "Season #{number}",
      episode_count: aired + upcoming,
      episodes: past ++ future
    }
  end

  defp episode(season, number, air_date) do
    %EpisodeData{
      season_number: season,
      episode_number: number,
      name: "Chapter #{season}.#{number}",
      air_date: air_date,
      runtime: 45
    }
  end
end
