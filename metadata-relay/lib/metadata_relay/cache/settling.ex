defmodule MetadataRelay.Cache.Settling do
  @moduledoc """
  Shortens the cache TTL for episode data that is still being filled in.

  `MetadataRelay.Cache` caches TVDB season and episode responses for 30 days
  and TMDB seasons for 14. That is right for an ended show and wrong for an
  airing one: TVDB publishes an upcoming episode as "TBA" and TMDB as
  "Episode 8", both rename it days later, and every install behind the relay
  kept the placeholder until the entry expired however often it asked.

  A response is settling when any episode in it aired within the last 14
  days, airs in the future, or has no air date and a placeholder name.
  Settling responses are cached for six hours; everything else keeps its
  path-based TTL.
  """

  @settling_ttl :timer.hours(6)
  @lookback_days 14

  # Mydia's `Mydia.Media.EpisodePlaceholder.title?/1`, restated because the
  # relay is deployed separately. The optional group also matches a blank name.
  @placeholder_name ~r/^(tba|tbd|tbc|episode\s*#?\d+)?$/

  @tvdb_season ~r{^GET:/tvdb/seasons/\d+/extended:}
  @tvdb_episode ~r{^GET:/tvdb/episodes/\d+/extended:}
  @tmdb_season ~r{^GET:/tmdb/tv/shows/\d+/\d+:}

  @doc """
  Returns the settling TTL in milliseconds for a cache `key` and its response
  `body`, or `nil` when the path-based TTL should stand.
  """
  @spec ttl(String.t(), String.t(), Date.t()) :: pos_integer() | nil
  def ttl(key, body, today \\ Date.utc_today())

  def ttl(key, body, %Date{} = today) when is_binary(key) and is_binary(body) do
    with {:ok, shape} <- shape(key),
         {:ok, decoded} <- Jason.decode(body),
         [_ | _] = episodes <- episodes(shape, decoded),
         true <- Enum.any?(episodes, &settling?(&1, today)) do
      @settling_ttl
    else
      _ -> nil
    end
  end

  def ttl(_key, _body, _today), do: nil

  defp shape(key) do
    cond do
      Regex.match?(@tvdb_season, key) -> {:ok, :tvdb_season}
      Regex.match?(@tvdb_episode, key) -> {:ok, :tvdb_episode}
      Regex.match?(@tmdb_season, key) -> {:ok, :tmdb_season}
      true -> :error
    end
  end

  # Each shape reduces to {air_date, name} pairs. An unexpected shape yields no
  # episodes, which keeps the path TTL instead of raising inside the cache
  # plug's before_send callback.
  defp episodes(:tvdb_season, %{"data" => %{"episodes" => episodes}}) when is_list(episodes),
    do: for(%{} = episode <- episodes, do: {episode["aired"], episode["name"]})

  defp episodes(:tvdb_episode, %{"data" => %{} = episode}),
    do: [{episode["aired"], episode["name"]}]

  defp episodes(:tmdb_season, %{"episodes" => episodes}) when is_list(episodes),
    do: for(%{} = episode <- episodes, do: {episode["air_date"], episode["name"]})

  defp episodes(_shape, _decoded), do: []

  # A placeholder name counts as settling only when the episode has no air
  # date. An episode that aired more than @lookback_days ago and still reads
  # "TBA" or "Episode 8" is almost always named that way permanently (daily
  # and long-running shows on TMDB carry thousands of numbered names), and
  # Mydia's airing refresh stops asking about it 14 days after air anyway.
  defp settling?({air_date, name}, today) do
    case parse_date(air_date) do
      %Date{} = date -> Date.compare(date, Date.add(today, -@lookback_days)) != :lt
      nil -> placeholder_name?(name)
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp placeholder_name?(nil), do: true

  defp placeholder_name?(name) when is_binary(name),
    do: Regex.match?(@placeholder_name, name |> String.trim() |> String.downcase())

  defp placeholder_name?(_name), do: false
end
