defmodule Mydia.Indexers.Cardigann.AdapterSupport do
  @moduledoc """
  Helpers shared by the two Cardigann adapters,
  `Mydia.Indexers.Adapter.Cardigann` (the Elixir engine) and
  `Mydia.Indexers.Cardigann.Wasm.Adapter` (Prowlarr's engine under Wasmex):
  definition lookup, the string-or-atom `setting/2` read, search-option
  filters, and FlareSolverr options and marking.
  """

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Repo

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

  @doc "FlareSolverr options for a definition."
  def build_flaresolverr_opts(%CardigannDefinition{} = definition) do
    %{
      enabled: CardigannDefinition.use_flaresolverr?(definition),
      definition_id: definition.id
    }
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
