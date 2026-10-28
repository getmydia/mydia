defmodule Mydia.Media.FranchiseLibrary do
  @moduledoc """
  Picks the library a movie should default to from where its franchise lives.

  A movie added from a TMDB collection that already has titles in the library
  should land beside them (#1293). `Mydia.Media.AddDefaults` asks this module
  before the user's own preference, and only when no library was chosen
  explicitly.

  Siblings are found locally first, by the `collection_id` pointer stored on
  each movie's metadata. When none carry it, the collection's parts come from
  the relay, are matched by `tmdb_id`, and get the pointer written back so the
  next add from that franchise stays local. A partly backfilled library can
  therefore see only some siblings for a while; the vote is over those.

  Only siblings with a real placement vote: an explicit library, or files that
  already live somewhere. A sibling with neither would resolve to the instance
  default, which says nothing about the franchise. The library with the most
  votes wins; a tie returns nil so the next layer decides.

  Every failure returns nil. An add must never fail because of this lookup.
  """

  import Ecto.Query

  require Logger

  alias Mydia.{DB, Metadata, Repo}
  alias Mydia.Library.TargetResolver
  alias Mydia.Media.{Franchises, MediaItem}
  alias Mydia.Metadata.Provider.Error

  @voting_reasons [:explicit, :existing_files]

  @doc """
  Returns the id of the library most of this movie's franchise lives in, or nil.

  `config` is the relay configuration; it defaults to
  `Metadata.default_relay_config/0` and exists so tests can inject a stub.
  """
  @spec library_for(integer() | nil, map() | nil) :: String.t() | nil
  def library_for(tmdb_id, config \\ nil)

  def library_for(tmdb_id, config) when is_integer(tmdb_id) do
    config = config || Metadata.default_relay_config()

    with {:ok, collection_id} <- collection_id_for(tmdb_id, config),
         [_ | _] = siblings <- siblings(tmdb_id, collection_id, config) do
      majority_library(siblings)
    else
      _ -> nil
    end
  end

  def library_for(_tmdb_id, _config), do: nil

  defp collection_id_for(tmdb_id, config) do
    case Metadata.fetch_by_ref_cached(config, {:tmdb, tmdb_id}, media_type: :movie) do
      {:ok, %{collection_id: id}} when is_integer(id) ->
        {:ok, id}

      {:ok, _no_franchise} ->
        :none

      {:error, %Error{type: :not_found}} ->
        :none

      {:error, reason} ->
        Logger.warning("Franchise library lookup failed for tmdb #{tmdb_id}: #{inspect(reason)}")
        :none
    end
  end

  defp siblings(tmdb_id, collection_id, config) do
    case local_siblings(tmdb_id, collection_id) do
      [] -> remote_siblings(tmdb_id, collection_id, config)
      found -> found
    end
  end

  defp local_siblings(tmdb_id, collection_id) do
    MediaItem
    |> where([m], m.type == "movie" and m.tmdb_id != ^tmdb_id)
    |> where(^DB.json_integer_equals(:metadata, "$.collection_id", collection_id))
    |> Repo.all()
  end

  defp remote_siblings(tmdb_id, collection_id, config) do
    case Metadata.fetch_collection_cached(config, collection_id) do
      {:ok, collection} ->
        ids =
          collection.parts
          |> Enum.flat_map(fn part ->
            case Integer.parse(part.provider_id || "") do
              {id, ""} when id != tmdb_id -> [id]
              _ -> []
            end
          end)

        MediaItem
        |> where([m], m.type == "movie" and m.tmdb_id in ^ids)
        |> Repo.all()
        |> Enum.map(&backfill(&1, collection_id, collection.name))

      {:error, %Error{type: :not_found}} ->
        []

      {:error, reason} ->
        Logger.warning(
          "Franchise library lookup failed for collection #{collection_id}: #{inspect(reason)}"
        )

        []
    end
  end

  defp backfill(%MediaItem{metadata: %{collection_id: id}} = item, id, _name), do: item

  defp backfill(%MediaItem{} = item, collection_id, name) do
    :ok = Franchises.persist_pointer(item, collection_id, name)
    item
  end

  defp majority_library(siblings) do
    siblings
    |> Enum.flat_map(fn item ->
      case TargetResolver.resolve(item) do
        {:ok, library, reason} when reason in @voting_reasons -> [library.id]
        _ -> []
      end
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_id, count} -> count end, :desc)
    |> case do
      [{_a, count}, {_b, count} | _] -> nil
      [{id, _count} | _] -> id
      [] -> nil
    end
  end
end
