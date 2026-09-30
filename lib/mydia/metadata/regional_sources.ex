defmodule Mydia.Metadata.RegionalSources do
  @moduledoc """
  What a user can watch in their home country: in cinemas, coming to cinemas,
  newest on the streaming services they picked, and titles made there.

  Every source is a TMDB `/discover` query, so Discover's rows, its See all
  grid and the Home widget all go through `Mydia.Metadata.discover/2` and get
  the same caching, certification limits and filters. The cinema sources use
  discover with a regional release window rather than TMDB's curated
  now_playing/upcoming lists, which accept none of those filters.

  TMDB has no "date added to a service", so a service source is "recent
  releases available on it, newest first", never "just added".
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference
  alias Mydia.Metadata
  alias Mydia.Metadata.Countries

  @type source :: :in_cinemas | :coming_soon | :made_here | {:service, pos_integer(), String.t()}

  @in_cinemas_days 42
  @coming_soon_days 90
  @service_min_votes 10

  @doc "Sources for a Discover row list, in display order."
  @spec sources_for(String.t() | nil, [map()], :movie | :tv_show) :: [source()]
  def sources_for(nil, _services, _media_type), do: []

  def sources_for(_country, services, media_type) do
    cinema = if media_type == :movie, do: [:in_cinemas, :coming_soon], else: []
    cinema ++ service_sources(services) ++ [:made_here]
  end

  @doc "Sources for the Home widget's chip row (movies and TV together)."
  @spec home_sources(String.t() | nil, [map()]) :: [source()]
  def home_sources(country, services), do: sources_for(country, services, :movie)

  defp service_sources(services),
    do: Enum.map(services, fn %{"id" => id, "name" => name} -> {:service, id, name} end)

  @doc "Whether a source only exists for movies."
  def movies_only?(source), do: source in [:in_cinemas, :coming_soon]

  @doc "The `Metadata.discover/2` options for a source, including `:sort_by`."
  @spec opts(source(), :movie | :tv_show, String.t(), Date.t()) :: keyword()
  def opts(:in_cinemas, :movie, country, today) do
    [
      region: country,
      with_release_type: "2|3",
      release_date_gte: iso(Date.add(today, -@in_cinemas_days)),
      release_date_lte: iso(today),
      sort_by: default_sort(:in_cinemas, :movie)
    ]
  end

  def opts(:coming_soon, :movie, country, today) do
    [
      region: country,
      with_release_type: "2|3",
      release_date_gte: iso(Date.add(today, 1)),
      release_date_lte: iso(Date.add(today, @coming_soon_days)),
      sort_by: default_sort(:coming_soon, :movie)
    ]
  end

  def opts({:service, id, _name} = source, media_type, country, today) do
    [
      watch_region: country,
      with_watch_providers: to_string(id),
      with_watch_monetization_types: "flatrate",
      release_date_lte: iso(today),
      min_votes: @service_min_votes,
      sort_by: default_sort(source, media_type)
    ]
  end

  def opts(:made_here, media_type, country, _today) do
    [origin_country: country, sort_by: default_sort(:made_here, media_type)]
  end

  @doc "The sort a source uses when the user has not picked one."
  def default_sort(:coming_soon, _media_type), do: "primary_release_date.asc"
  def default_sort({:service, _, _}, :tv_show), do: "first_air_date.desc"
  def default_sort({:service, _, _}, _movie), do: "primary_release_date.desc"
  def default_sort(_source, _media_type), do: "popularity.desc"

  @doc "Row and chip title."
  def label(:in_cinemas, _country), do: "In cinemas"
  def label(:coming_soon, _country), do: "Coming soon"
  def label({:service, _id, name}, _country), do: "Latest on #{name}"
  def label(:made_here, country), do: "Made in #{Countries.name(country)}"

  @doc "URL-safe name for a source."
  def to_param(:in_cinemas), do: "in_cinemas"
  def to_param(:coming_soon), do: "coming_soon"
  def to_param(:made_here), do: "made_here"
  def to_param({:service, id, _name}), do: "service-#{id}"

  @doc """
  The source in `sources` whose param is `param`, or nil. Resolving against
  the user's own list means a forged or stale `service-<id>` finds nothing.
  """
  def find(sources, param) when is_binary(param),
    do: Enum.find(sources, &(to_param(&1) == param))

  def find(_sources, _param), do: nil

  @doc """
  Page 1 of a source. `extra_opts` carries caller-side options such as the
  certification ceiling from `Mydia.Media.RemoteFilter.discover_params/1`.
  """
  def fetch(source, media_type, country, extra_opts, today) do
    opts = Keyword.merge(opts(source, media_type, country, today), extra_opts)

    case Metadata.discover(media_type, opts) do
      {:ok, %{results: results}} -> {:ok, results}
      {:error, _} = error -> error
    end
  end

  @doc """
  Movies and TV for one source, for the Home widget's single rail. Service
  sources merge newest first; made here alternates, since popularity scores
  are not comparable across the two lists. Fails only if both fetches fail.
  """
  def fetch_mixed(source, country, extra_opts, today) do
    if movies_only?(source) do
      fetch(source, :movie, country, extra_opts, today)
    else
      [:movie, :tv_show]
      |> Task.async_stream(&fetch(source, &1, country, extra_opts, today), timeout: :infinity)
      |> Enum.map(fn {:ok, result} -> result end)
      |> merge_mixed(source)
    end
  end

  defp merge_mixed([{:error, _} = error, {:error, _}], _source), do: error

  defp merge_mixed(results, source) do
    [movies, shows] = Enum.map(results, &ok_or_empty/1)

    merged =
      case source do
        {:service, _, _} -> Enum.sort_by(movies ++ shows, &date_key/1, :desc)
        _ -> alternate(movies, shows)
      end

    {:ok, merged}
  end

  defp ok_or_empty({:ok, list}), do: list
  defp ok_or_empty(_), do: []

  # SearchResult dates are ISO strings or Date structs; both sort as ISO text.
  defp date_key(item), do: to_string(item.release_date || item.first_air_date || "")

  defp alternate([a | as], [b | bs]), do: [a, b | alternate(as, bs)]
  defp alternate(as, []), do: as
  defp alternate([], bs), do: bs

  @doc "Services TMDB lists for a country, movie and TV lists merged by id."
  def available_services(country) do
    results = Enum.map([:movie, :tv_show], &Metadata.watch_providers(&1, country))

    case Enum.filter(results, &match?({:ok, _}, &1)) do
      [] ->
        hd(results)

      oks ->
        providers =
          oks
          |> Enum.flat_map(fn {:ok, list} -> list end)
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(& &1.display_priority)

        {:ok, providers}
    end
  end

  @doc """
  Saves a new home country (nil removes it) and prunes the saved services to
  the ones the new country offers. A service from the old country means
  nothing in the new one, so if the new list cannot be fetched the services
  are cleared rather than kept.
  """
  def change_home_country(user, code, available_fun \\ &available_services/1) do
    pref = Accounts.get_user_preference!(user)
    current = Map.get(pref.preferences || %{}, "discover_streaming_services") || []

    services =
      cond do
        is_nil(code) or current == [] -> []
        code == UserPreference.discover_home_country(pref) -> current
        true -> keep_available(current, available_fun.(code))
      end

    Accounts.update_preference(pref, %{
      "preferences" => %{
        "discover_home_country" => code,
        "discover_streaming_services" => services
      }
    })
  end

  defp keep_available(current, {:ok, providers}) do
    ids = MapSet.new(providers, & &1.id)
    Enum.filter(current, &MapSet.member?(ids, &1["id"]))
  end

  defp keep_available(_current, {:error, _}), do: []

  @doc "Saves the picked services, in order."
  def put_services(user, services) do
    user
    |> Accounts.get_user_preference!()
    |> Accounts.update_preference(%{
      "preferences" => %{"discover_streaming_services" => services}
    })
  end

  defp iso(date), do: Date.to_iso8601(date)
end
