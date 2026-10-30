defmodule Mydia.Indexers.Cardigann.AdapterSupport do
  @moduledoc """
  Helpers shared by the two Cardigann adapters,
  `Mydia.Indexers.Adapter.Cardigann` (the Elixir engine) and
  `Mydia.Indexers.Cardigann.Wasm.Adapter` (Prowlarr's engine under Wasmex):
  definition lookup, the string-or-atom `setting/2` read, search-option
  filters, release validity, and FlareSolverr options and marking.
  """

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.{CardigannDefinition, CardigannHealthCheck}
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Repo

  # How many mirrors one search tries before giving up.
  @max_search_candidates 3

  @doc """
  Marks every result private or public from the definition's `type`:
  `private` and `semi-private` are private, `public` is not, anything else
  leaves the terms as they are. Both engines report volume factors per
  release, but privacy belongs to the definition, so it is added here for
  both.
  """
  @spec put_definition_privacy([SearchResult.t()], String.t() | nil) :: [SearchResult.t()]
  def put_definition_privacy(results, type) do
    case definition_private?(type) do
      nil ->
        results

      private? ->
        Enum.map(results, fn result ->
          terms = result.terms || %TrackerTerms{}
          %{result | terms: %{terms | private?: private?}}
        end)
    end
  end

  defp definition_private?(type) when type in ["private", "semi-private"], do: true
  defp definition_private?("public"), do: false
  defp definition_private?(_type), do: nil

  @doc "Loads the definition row named by `config.indexer_id`."
  @spec fetch_definition(map()) :: {:ok, CardigannDefinition.t()} | {:error, Error.t()}
  def fetch_definition(%{indexer_id: indexer_id}) do
    case Repo.get_by(CardigannDefinition, indexer_id: indexer_id) do
      nil ->
        {:error, Error.invalid_config("Cardigann definition not found: #{indexer_id}")}

      definition ->
        {:ok, definition}
    end
  end

  def fetch_definition(_config) do
    {:error, Error.invalid_config("Missing indexer_id in config")}
  end

  # Credentials are read by name rather than by key type. `definition.config` is
  # a `Mydia.Settings.JsonMapType`, so anything that has been through the
  # database comes back from `Jason.decode/1` with string keys, and the admin
  # form supplies string keys too. Reading only atoms meant every configured
  # private indexer authenticated with empty credentials: the login failed, the
  # search returned nothing, and the connection test now reports a failure the
  # tracker never caused.
  @doc "Reads `key` from a map whether it is stored under the atom or its string."
  @spec setting(term(), atom()) :: term()
  def setting(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def setting(_map, _key), do: nil

  @doc "True for nil, blank strings, empty lists and empty maps."
  @spec blank?(term()) :: boolean()
  def blank?(nil), do: true
  def blank?(value) when is_binary(value), do: String.trim(value) == ""
  def blank?([]), do: true
  def blank?(%{} = value), do: map_size(value) == 0
  def blank?(_value), do: false

  @doc "Applies `:min_seeders`, `:min_size`, `:max_size` and `:limit` from `opts`."
  def apply_search_filters(results, opts) do
    results
    |> filter_by_min_seeders(Keyword.get(opts, :min_seeders, 0))
    |> filter_by_min_size(Keyword.get(opts, :min_size))
    |> filter_by_max_size(Keyword.get(opts, :max_size))
    |> limit_results(Keyword.get(opts, :limit))
  end

  defp filter_by_min_seeders(results, min_seeders) when min_seeders > 0 do
    # NZB results have nil seeders; the min-seeders setting is torrent-only.
    Enum.filter(results, fn result -> is_nil(result.seeders) or result.seeders >= min_seeders end)
  end

  defp filter_by_min_seeders(results, _), do: results

  defp filter_by_min_size(results, nil), do: results

  defp filter_by_min_size(results, min_size) do
    Enum.filter(results, fn result -> result.size >= min_size end)
  end

  defp filter_by_max_size(results, nil), do: results

  defp filter_by_max_size(results, max_size) do
    Enum.filter(results, fn result -> result.size <= max_size end)
  end

  defp limit_results(results, nil), do: results
  defp limit_results(results, limit), do: Enum.take(results, limit)

  @doc """
  Prowlarr's `HttpIndexerBase.IsValidRelease`: outside an interactive search
  (`interactive: true`, which the manual search UI passes), a release with no
  category or no size is dropped. Prowlarr checks for a null size; the
  built-in engine has 0 for an absent or unreadable one. A category of 0 is
  the engine's unmapped value, not a Torznab id. The wasm engine's guest
  already applies the rule, so only the built-in adapter calls this.

  Each dropped release is logged at debug with its reason, and a search that
  dropped anything logs one warning naming `indexer_name`. The health check
  does not search through the adapter, so a definition whose site renumbered
  its categories stays healthy while every automatic search comes back empty;
  the warning is the only trace of that.
  """
  @spec drop_invalid_releases([SearchResult.t()], keyword(), String.t() | nil) ::
          [SearchResult.t()]
  def drop_invalid_releases(results, opts, indexer_name) do
    if Keyword.get(opts, :interactive, false) do
      results
    else
      {kept, dropped} =
        Enum.split_with(results, fn result -> invalid_reason(result) == nil end)

      log_dropped(dropped, length(results), indexer_name)
      kept
    end
  end

  defp invalid_reason(%{category: category}) when not is_integer(category) or category <= 0,
    do: :no_category

  defp invalid_reason(%{size: size}) when not is_integer(size) or size <= 0, do: :no_size
  defp invalid_reason(_result), do: nil

  defp log_dropped([], _total, _indexer_name), do: :ok

  defp log_dropped(dropped, total, indexer_name) do
    reasons =
      Enum.map(dropped, fn result ->
        reason = invalid_reason(result)
        Logger.debug("#{indexer_name} dropped #{inspect(result.title)}: #{reason}")
        reason
      end)

    counts =
      reasons
      |> Enum.frequencies()
      |> Enum.sort()
      |> Enum.map_join(", ", fn {reason, count} -> "#{reason}: #{count}" end)

    Logger.warning(dropped_summary(length(dropped), total, indexer_name, counts))
  end

  defp dropped_summary(total, total, indexer_name, counts) do
    "#{indexer_name} dropped all #{total} releases (#{counts}) as invalid outside a " <>
      "manual search; the definition's category mappings may be stale"
  end

  defp dropped_summary(dropped, total, indexer_name, counts) do
    "#{indexer_name} dropped #{dropped} of #{total} releases (#{counts}) as invalid " <>
      "outside a manual search"
  end

  @doc "FlareSolverr options for a definition."
  def build_flaresolverr_opts(%CardigannDefinition{} = definition) do
    %{
      enabled: CardigannDefinition.use_flaresolverr?(definition),
      definition_id: definition.id
    }
  end

  @doc """
  The base URLs a search tries, in order: the definition's sticky `active_link`,
  then its `links` and `legacylinks`, at most three. `legacy: false` leaves the
  `legacylinks` out.
  """
  @spec search_candidates(Parsed.t(), String.t() | nil, keyword()) :: [String.t()]
  def search_candidates(%Parsed{} = parsed, active_link, opts \\ []) do
    listed =
      if Keyword.get(opts, :legacy, true),
        do: Links.candidates(parsed),
        else: Links.current(parsed)

    (Enum.map(List.wrap(active_link), &String.trim_trailing(&1, "/")) ++ listed)
    |> Enum.uniq()
    |> Enum.take(@max_search_candidates)
  end

  @doc """
  Stores a mirror that answered after another had failed as the definition's
  sticky `active_link`, unless it is a legacy mirror that would readmit a host
  the credential scope excludes (see `CardigannHealthCheck.promotable?/3`).
  """
  @spec promote_active_link(Parsed.t(), CardigannDefinition.t(), String.t()) :: term()
  def promote_active_link(%Parsed{} = parsed, %CardigannDefinition{} = definition, winning_url) do
    if CardigannHealthCheck.promotable?(parsed, definition.config || %{}, winning_url) do
      definition
      |> Ecto.Changeset.change(%{active_link: winning_url})
      |> Repo.update()
    else
      :ok
    end
  end

  @doc "Flags the definition when a challenge was solved for it."
  def handle_flaresolverr_result(definition, {:flaresolverr_markers, markers}) do
    if {:flaresolverr_required, true} in markers do
      mark_flaresolverr_required(definition)
    end

    :ok
  end

  def handle_flaresolverr_result(_definition, :no_flaresolverr), do: :ok

  @doc "Marks an indexer as requiring FlareSolverr."
  def mark_flaresolverr_required(%CardigannDefinition{flaresolverr_required: true}), do: :ok

  def mark_flaresolverr_required(%CardigannDefinition{} = definition) do
    Logger.info("Auto-detected FlareSolverr requirement for indexer: #{definition.indexer_id}")

    definition
    |> CardigannDefinition.flaresolverr_changeset(%{
      flaresolverr_required: true,
      flaresolverr_enabled: true
    })
    |> Repo.update()
    |> case do
      {:ok, _} ->
        Logger.debug("Updated indexer #{definition.indexer_id} FlareSolverr settings")

      {:error, changeset} ->
        Logger.error("Failed to update FlareSolverr settings: #{inspect(changeset.errors)}")
    end
  end
end
