defmodule Mydia.Metadata.Provider.TvdbCastLink do
  @moduledoc """
  Gives TVDB cast members their TMDB person id.

  TVDB cast carries no TMDB person id, so `Mydia.Metadata.Provider.Relay` links it
  through the TMDB cross-reference in `remoteIds`: the matching TMDB show's
  aggregate cast maps names to ids. A name that appears twice maps to nothing,
  since guessing would attach the wrong person. Cached for a day; a failure
  degrades to the unlinked cast and is not cached, so it is retried on the next
  fetch.
  """

  require Logger

  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider.HTTP
  alias Mydia.Metadata.Structs.CastMember

  @doc """
  Returns `cast` with `tmdb_person_id` set on every member whose name matches
  exactly one person in the TMDB show `tmdb_id`. A nil `tmdb_id` or an empty cast
  returns `cast` unchanged.
  """
  @spec link(map(), String.t() | nil, [CastMember.t()]) :: [CastMember.t()]
  def link(config, tmdb_id, [_ | _] = cast) when is_binary(tmdb_id) do
    case Cache.fetch(
           "tvdb_tmdb_people:#{tmdb_id}",
           fn -> request_tmdb_people(config, tmdb_id) end,
           ttl: :timer.hours(24)
         ) do
      {:ok, ids_by_name} -> Enum.map(cast, &put_person_id(&1, ids_by_name))
      _ -> cast
    end
  end

  def link(_config, _tmdb_id, cast), do: cast

  defp put_person_id(member, ids_by_name) do
    case Map.get(ids_by_name, normalize_name(member.name)) do
      nil -> member
      id -> %{member | tmdb_person_id: id}
    end
  end

  defp request_tmdb_people(config, tmdb_id) do
    req = HTTP.new_request(config)

    case HTTP.get(req, "/tmdb/tv/shows/#{tmdb_id}",
           params: [append_to_response: "aggregate_credits"]
         ) do
      {:ok, %{status: 200, body: %{"aggregate_credits" => %{"cast" => tmdb_cast}}}}
      when is_list(tmdb_cast) ->
        {:ok, unique_person_ids(tmdb_cast)}

      {:ok, %{status: 200}} ->
        {:ok, %{}}

      other ->
        Logger.debug("TMDB cast cross-reference failed; leaving it uncached",
          tmdb_id: tmdb_id,
          result: inspect(other)
        )

        {:error, :tmdb_people_unavailable}
    end
  end

  defp unique_person_ids(tmdb_cast) do
    tmdb_cast
    |> Enum.filter(&(is_map(&1) and is_binary(&1["name"]) and is_integer(&1["id"])))
    |> Enum.group_by(&normalize_name(&1["name"]), & &1["id"])
    |> Enum.flat_map(fn {name, ids} ->
      case Enum.uniq(ids) do
        [id] -> [{name, id}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp normalize_name(name) do
    name
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.trim()
  end
end
