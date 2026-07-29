defmodule Mydia.Media.Franchises do
  @moduledoc """
  Resolves a movie's TMDB collection (franchise) and joins it against the library.

  The franchise pointer stored on a movie's metadata is treated as a cache, never
  as the source of truth: when it is absent, a cached movie-details fetch supplies
  it and the value is written back. That makes the feature work on libraries whose
  movies were added before the pointer existed, without a migration or a backfill
  job.

  Every failure — an old relay, an unreachable relay, a movie with no franchise —
  returns `:none`, so the caller has exactly one thing to check.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Mydia.{Media, Metadata, Repo}
  alias Mydia.Media.{Franchise, FranchiseEntry, MediaItem}

  @doc """
  Returns the franchise for a movie, or `:none`.

  `config` is the relay configuration; it defaults to
  `Metadata.default_relay_config/0` and exists so tests can inject a stub without
  touching global environment.
  """
  @spec for_media_item(MediaItem.t(), map() | nil) :: {:ok, Franchise.t()} | :none
  def for_media_item(media_item, config \\ nil)

  def for_media_item(%MediaItem{type: "movie", tmdb_id: tmdb_id} = item, config)
      when is_integer(tmdb_id) do
    config = config || Metadata.default_relay_config()

    with {:ok, collection_id} <- resolve_collection_id(item, config),
         {:ok, collection} <- fetch_collection(collection_id, config) do
      build(collection, item)
    else
      :none -> :none
    end
  end

  def for_media_item(_media_item, _config), do: :none

  ## Pointer resolution

  defp resolve_collection_id(%MediaItem{metadata: %{collection_id: id}}, _config)
       when is_integer(id),
       do: {:ok, id}

  defp resolve_collection_id(%MediaItem{tmdb_id: tmdb_id} = item, config) do
    case Metadata.fetch_by_id_cached(config, to_string(tmdb_id), media_type: :movie) do
      {:ok, %{collection_id: id} = fresh} when is_integer(id) ->
        persist_pointer(item, fresh)
        {:ok, id}

      {:ok, _no_franchise} ->
        :none

      {:error, reason} ->
        Logger.warning("Franchise pointer lookup failed for tmdb #{tmdb_id}: #{inspect(reason)}")

        :none
    end
  end

  # Writes the pointer back with a bare changeset rather than
  # Media.update_media_item/3, which emits a timeline event on every call. This
  # runs on page views; it must stay silent.
  defp persist_pointer(%MediaItem{metadata: nil}, _fresh), do: :ok

  defp persist_pointer(%MediaItem{} = item, fresh) do
    updated = %{
      item.metadata
      | collection_id: fresh.collection_id,
        collection_name: fresh.collection_name
    }

    item
    |> MediaItem.changeset(%{metadata: updated})
    |> Repo.update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Could not persist franchise pointer: #{inspect(changeset.errors)}")
        :ok
    end
  end

  ## Parts

  defp fetch_collection(collection_id, config) do
    case Metadata.fetch_collection_cached(config, collection_id) do
      {:ok, collection} ->
        {:ok, collection}

      {:error, reason} ->
        Logger.warning(
          "Franchise lookup failed for collection #{collection_id}: #{inspect(reason)}"
        )

        :none
    end
  end

  ## Assembly

  defp build(collection, %MediaItem{} = item) do
    entries =
      collection.parts
      |> Enum.map(&to_entry/1)
      |> Enum.reject(&is_nil/1)

    # A franchise of one is the movie you are already looking at.
    if length(entries) < 2 do
      :none
    else
      status = Media.library_status_for_tmdb_ids(Enum.map(entries, & &1.tmdb_id))

      entries =
        entries
        |> Enum.map(&decorate(&1, status, item))
        |> Enum.sort(&by_release_date/2)

      {:ok,
       %Franchise{
         name: collection.name,
         entries: entries,
         owned_count: Enum.count(entries, & &1.in_library?),
         total_count: length(entries)
       }}
    end
  end

  defp to_entry(part) do
    case Integer.parse(part.provider_id || "") do
      {tmdb_id, ""} ->
        %FranchiseEntry{
          tmdb_id: tmdb_id,
          title: part.title,
          year: part.release_date && part.release_date.year,
          release_date: part.release_date,
          poster_path: part.poster_path
        }

      _ ->
        nil
    end
  end

  defp decorate(entry, status, %MediaItem{tmdb_id: current_tmdb_id}) do
    entry = %{entry | current?: entry.tmdb_id == current_tmdb_id}

    case Map.get(status, entry.tmdb_id) do
      %{id: media_item_id} -> %{entry | in_library?: true, media_item_id: media_item_id}
      nil -> entry
    end
  end

  # Date structs compare as maps under the default term order (:calendar, :day,
  # :month, :year), which is not chronological. Date.compare/2 is required.
  defp by_release_date(%{release_date: nil}, %{release_date: nil}), do: true
  defp by_release_date(%{release_date: nil}, _b), do: false
  defp by_release_date(_a, %{release_date: nil}), do: true
  defp by_release_date(a, b), do: Date.compare(a.release_date, b.release_date) != :gt
end
