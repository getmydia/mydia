defmodule Mydia.Media.FixMatch do
  @moduledoc """
  Re-points a wrongly matched movie or show at the title it really is.

  An item accepted under the wrong title keeps its settings (monitoring,
  quality profile, collections) and only its identity changes. The search
  runs against the item's own provider with the operator's query, because the
  item's stored title is the wrong one and searching by it is how the bad
  match was made.

  Changing provider is not this module's job: the library's provider setting
  and `Mydia.Media.ProviderSwitch` own that.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Media.{MediaItem, ProviderSwitch, Refresh, RemoteFilter}
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult

  @doc "The provider a fix-match searches and adopts from."
  @spec provider_for(MediaItem.t()) :: :tmdb | :tvdb
  def provider_for(%MediaItem{type: "movie"}), do: :tmdb

  def provider_for(%MediaItem{} = item) do
    case Refresh.resolve_provider(item) do
      {_id, source} when source in [:tmdb, :tvdb] ->
        source

      _ ->
        case ProviderSwitch.resolve_library_provider(item) do
          {:ok, provider} -> provider
          _ -> :tmdb
        end
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

  defp media_type(%MediaItem{type: "tv_show"}), do: :tv_show
  defp media_type(%MediaItem{}), do: :movie
end
