defmodule Mydia.Media.FixMatch do
  @moduledoc """
  Re-points a wrongly matched movie or show at the title it really is.

  An item accepted under the wrong title keeps its settings (monitoring,
  quality profile, collections) and only its identity changes. The search
  runs against the item's own provider with the operator's query, because the
  item's stored title is the wrong one and searching by it is how the bad
  match was made.

  Changing provider is not this module's job: the library's provider setting
  and `Mydia.Media.ProviderSwitch` own that. A show is fixed on its library's
  provider, so the next Refresh does not re-identify it away from the fix.
  """

  import Ecto.Query, only: [from: 2]

  alias Mydia.Accounts.Scope
  alias Mydia.Media.{MediaItem, ProviderSwitch, Refresh, RemoteFilter}
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.Repo

  @doc """
  The provider a fix-match searches and adopts from.

  Movies use TMDB. A show uses its library's provider, so a fix lands where
  `ProviderSwitch.provider_refresh_decision/1` already expects it and Refresh
  will not re-identify it away. With no single library provider it falls back
  to the show's stored source, then TMDB.
  """
  @spec provider_for(MediaItem.t()) :: :tmdb | :tvdb
  def provider_for(%MediaItem{type: "movie"}), do: :tmdb

  def provider_for(%MediaItem{id: nil} = item), do: stored_provider(item)

  def provider_for(%MediaItem{} = item) do
    case ProviderSwitch.resolve_library_provider(item) do
      {:ok, provider} when provider in [:tmdb, :tvdb] -> provider
      _ -> stored_provider(item)
    end
  end

  defp stored_provider(item) do
    case Refresh.resolve_provider(item) do
      {_id, source} when source in [:tmdb, :tvdb] -> source
      _ -> :tmdb
    end
  end

  @doc "The item's current id at `provider_for/1`, as the string a search result carries."
  @spec current_provider_id(MediaItem.t()) :: String.t() | nil
  def current_provider_id(%MediaItem{} = item) do
    case {provider_for(item), item} do
      {:tmdb, %{tmdb_id: id}} when not is_nil(id) -> to_string(id)
      {:tvdb, %{tvdb_id: id}} when not is_nil(id) -> to_string(id)
      _ -> nil
    end
  end

  @doc """
  Searches the item's provider for `query`, retrying without `year` when the
  year filter finds nothing. Results a restricted `scope` may not see are
  dropped.
  """
  @spec search(MediaItem.t(), String.t(), integer() | nil, Scope.t(), map() | nil) ::
          {:ok, [SearchResult.t()]} | {:error, term()}
  def search(%MediaItem{} = item, query, year, %Scope{} = scope, config \\ nil) do
    config = config || Metadata.default_relay_config()
    base_opts = [media_type: media_type(item), provider: provider_for(item)]

    with {:ok, results} <- search_with_year_fallback(config, query, year, base_opts) do
      {:ok, RemoteFilter.filter(results, scope, config: config)}
    end
  end

  defp search_with_year_fallback(config, query, nil, opts),
    do: Metadata.search(config, query, opts)

  defp search_with_year_fallback(config, query, year, opts) do
    case Metadata.search(config, query, [{:year, year} | opts]) do
      {:ok, []} -> Metadata.search(config, query, opts)
      other -> other
    end
  end

  @doc """
  Re-points `item` at `candidate` on the item's own provider.

  A movie is rewritten in place and keeps its files. A show goes through
  `ProviderSwitch.adopt_provider_switch/5`, which rebuilds its episodes from
  the new id and sends their files back through import. Refuses with
  `{:already_in_library, other}` when another item already holds that id,
  because merging two items is not something this does.
  """
  @spec adopt(Scope.t(), MediaItem.t(), struct(), map() | nil) ::
          {:ok, MediaItem.t()} | {:error, {:already_in_library, MediaItem.t()} | term()}
  def adopt(%Scope{} = scope, %MediaItem{} = item, candidate, config \\ nil) do
    config = config || Metadata.default_relay_config()
    provider = provider_for(item)
    new_id = String.to_integer(to_string(candidate.provider_id))

    cond do
      not candidate_from?(candidate, provider) ->
        {:error, {:provider_mismatch, candidate.provider, provider}}

      other = holder_of(item, provider, new_id) ->
        {:error, {:already_in_library, other}}

      true ->
        do_adopt(scope, item, candidate, provider, new_id, config)
    end
  end

  # An id is only meaningful on the provider that issued it. A candidate from a
  # search made before the item's library changed provider would otherwise be
  # written into the wrong id column. Results that do not name a concrete
  # provider are trusted, since they came from `search/5` for this item.
  defp candidate_from?(%{provider: p}, provider) when p in [:tmdb, :tvdb], do: p == provider
  defp candidate_from?(_candidate, _provider), do: true

  defp do_adopt(scope, %MediaItem{type: "tv_show"} = item, candidate, provider, _id, config),
    do: ProviderSwitch.adopt_provider_switch(scope, item, candidate, provider, config)

  defp do_adopt(scope, %MediaItem{} = item, _candidate, provider, new_id, config) do
    with {:ok, metadata} <-
           Metadata.fetch_by_ref(config, {provider, new_id},
             media_type: :movie,
             append_to_response: Metadata.default_append_to_response(:movie)
           ),
         {:ok, updated} <-
           Refresh.write_metadata(scope, item, metadata, provider, reason(item, metadata)) do
      Mydia.Metadata.NfoWriter.maybe_write_nfos(updated)
      {:ok, updated}
    end
  end

  defp reason(item, metadata), do: "Match changed from #{item.title} to #{metadata.title}"

  defp holder_of(%MediaItem{id: id, type: type}, :tmdb, new_id),
    do:
      Repo.one(
        from m in MediaItem,
          where: m.type == ^type and m.tmdb_id == ^new_id and m.id != ^id,
          limit: 1
      )

  defp holder_of(%MediaItem{id: id, type: type}, :tvdb, new_id),
    do:
      Repo.one(
        from m in MediaItem,
          where: m.type == ^type and m.tvdb_id == ^new_id and m.id != ^id,
          limit: 1
      )

  defp media_type(%MediaItem{type: "tv_show"}), do: :tv_show
  defp media_type(%MediaItem{}), do: :movie
end
