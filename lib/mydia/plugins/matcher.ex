defmodule Mydia.Plugins.Matcher do
  @moduledoc """
  Centralized external-ID matcher for plugin write-backs (U6).

  Resolves a `watch-target` (external ids plus optional episode coordinates) to a
  local content reference — `{:movie, media_item_id}` or `{:episode, episode_id}`
  — in one tested place. Keeping ID-mapping logic here, rather than letting each
  plugin enumerate the library, means the ordered-candidate / explicit-fallback
  rules (the TVDB language-selection lesson) live in a single module.

  Resolution rules:

    * Episode coordinates present (`season` and `episode` both integers) → the
      external ids identify the *show*; the episode is pinned within it. A show
      that resolves but lacks the episode is `:not_found` (no silent
      fall-through to the show — the media-server sync's silent skip is the
      anti-pattern).
    * No coordinates → the external ids identify a movie.

  External ids are resolved through `Mydia.Media.find_by_external_ids/2`, which
  cascades imdb → tvdb → tmdb, advancing on a lookup miss rather than a missing
  id. `match/1` pins the expected type so a movie id cannot resolve to a show,
  while `match_item/1` deliberately accepts either.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Media

  @type target :: %{
          optional(:imdb) => String.t() | nil,
          optional(:tmdb) => integer() | nil,
          optional(:tvdb) => integer() | nil,
          optional(:season) => integer() | nil,
          optional(:episode) => integer() | nil
        }

  @type result :: {:movie, binary()} | {:episode, binary()} | :not_found
  @type item_result :: {:media_item, binary()} | :not_found

  @doc """
  Resolves `target` to a local media item (movie or show), ignoring any episode
  coordinates.

  Item-level write surfaces (favorites, list membership) address a show as a
  whole, so they must not fall through to an episode the way `match/1` does.
  """
  @spec match_item(target()) :: item_result()
  def match_item(target) when is_map(target) do
    case Media.find_by_external_ids(Scope.system(), external_ids(target)) do
      %{id: id} -> {:media_item, id}
      _ -> :not_found
    end
  end

  @doc """
  Resolves `target` to a local content reference, or `:not_found`.
  """
  @spec match(target()) :: result()
  def match(target) when is_map(target) do
    ids = external_ids(target)

    case episode_coords(target) do
      {season, number} -> match_episode(ids, season, number)
      nil -> match_movie(ids)
    end
  end

  defp match_movie(ids) do
    case Media.find_by_external_ids(Scope.system(), ids, type: "movie") do
      %{id: id} -> {:movie, id}
      _ -> :not_found
    end
  end

  defp match_episode(ids, season, number) do
    with %{id: show_id} <- Media.find_by_external_ids(Scope.system(), ids, type: "tv_show"),
         %{id: episode_id} <- Media.find_episode(Scope.system(), show_id, season, number) do
      {:episode, episode_id}
    else
      _ -> :not_found
    end
  end

  defp external_ids(target) do
    %{
      imdb: Map.get(target, :imdb),
      tvdb: Map.get(target, :tvdb),
      tmdb: Map.get(target, :tmdb)
    }
  end

  defp episode_coords(target) do
    season = Map.get(target, :season)
    number = Map.get(target, :episode)

    if is_integer(season) and is_integer(number), do: {season, number}, else: nil
  end
end
