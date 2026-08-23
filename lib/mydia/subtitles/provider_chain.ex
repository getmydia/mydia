defmodule Mydia.Subtitles.ProviderChain do
  @moduledoc """
  Searches every enabled subtitle provider at once and merges what comes back.

  Providers are queried concurrently rather than walked in order. Walking costs
  one round trip per provider and lets the slowest one decide how long the user
  stares at a spinner. Each provider gets its own deadline, and a provider that
  misses it is abandoned rather than allowed to hold up the rest.

  A provider that cannot answer the question is never asked. Gestdown serves
  episodes keyed on a TVDB id, so a movie search skips it instead of spending a
  request and a full timeout learning that again.

  Whatever fails is reported rather than hidden. The caller receives every
  provider's outcome alongside the merged results, so the UI can say which
  upstream is down instead of showing an empty list.
  """

  require Logger

  alias Mydia.Settings.ServiceConfigs
  alias Mydia.Subtitles.Health
  alias Mydia.Subtitles.ProviderRegistry

  @default_timeout 8_000

  @doc """
  Searches every eligible enabled provider concurrently.

  Always returns `{:ok, _}`. A total failure is an empty result list with every
  provider carrying an error, which the caller renders differently from a
  successful search that found nothing.
  """
  @spec search(map()) :: {:ok, %{results: [map()], providers: [map()]}}
  def search(params) do
    configs =
      [enabled: true]
      |> ServiceConfigs.list_subtitle_provider_configs()
      |> Enum.filter(fn config ->
        Health.available?(config.type) and
          eligible?(ProviderRegistry.adapter_for(config).capabilities(), params)
      end)

    outcomes = run_all(configs, params)

    results =
      outcomes
      |> Enum.flat_map(fn
        {config, {:ok, provider_results}} -> Enum.map(provider_results, &tag(&1, config))
        {_config, {:error, _reason}} -> []
      end)
      |> dedupe()

    statuses =
      Enum.map(outcomes, fn
        {config, {:ok, _}} ->
          Health.record_success(config.type)
          status(config, nil)

        {config, {:error, reason}} ->
          Health.record_failure(config.type)
          status(config, describe(reason))
      end)

    {:ok, %{results: results, providers: statuses}}
  end

  @doc """
  Returns true when a provider's capabilities can serve these search params.

  A provider must handle the media type and accept at least one of the search
  keys the caller actually has.
  """
  @spec eligible?(map(), map()) :: boolean()
  def eligible?(capabilities, params) do
    media_type_ok?(capabilities, params) and search_key_ok?(capabilities, params)
  end

  ## Private

  defp media_type_ok?(capabilities, params) do
    case Map.get(params, :media_type) do
      "movie" -> :movie in capabilities.media_types
      "episode" -> :episode in capabilities.media_types
      # No media type stated, so do not exclude anyone on this basis.
      _ -> true
    end
  end

  # When the caller supplied no searchable keys (language + media type only), do
  # not exclude anyone on this basis. Otherwise require an intersection with the
  # provider's accepted keys so a TVDB-only provider is skipped for an IMDB-only
  # query.
  defp search_key_ok?(capabilities, params) do
    case present_search_keys(params) do
      [] -> true
      keys -> Enum.any?(capabilities.search_keys, &(&1 in keys))
    end
  end

  defp present_search_keys(params) do
    Enum.filter([:file_hash, :imdb_id, :tmdb_id, :tvdb_id, :query], fn key ->
      case Map.get(params, key) do
        nil -> false
        "" -> false
        _ -> true
      end
    end)
  end

  # Every provider starts immediately and carries its own absolute deadline, so a
  # provider configured with a short timeout is abandoned at that timeout even
  # when a slower sibling is still allowed to run.
  defp run_all([], _params), do: []

  defp run_all(configs, params) do
    configs
    |> Enum.map(fn config ->
      deadline = System.monotonic_time(:millisecond) + timeout_for(config)
      {config, deadline, Task.async(fn -> run_search(config, params) end)}
    end)
    |> Enum.map(fn {config, deadline, task} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {config, result}

        nil ->
          Logger.warning("Subtitle provider exceeded its deadline", provider: config.name)
          {config, {:error, :timeout}}

        {:exit, reason} ->
          Logger.warning("Subtitle provider crashed",
            provider: config.name,
            reason: inspect(reason)
          )

          {config, {:error, {:crashed, reason}}}
      end
    end)
  end

  defp timeout_for(config) do
    case Map.get(config, :connection_settings) do
      %{"timeout" => timeout} when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @default_timeout
    end
  end

  defp run_search(config, params) do
    ProviderRegistry.adapter_for(config).search(config, params)
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # `provider_name` is a display field. A proxying provider reports the upstream
  # it actually reached as the result's origin, and that is what the UI should
  # name. `config.name` is the fallback, and remains what the provider status
  # list shows, so a relay outage is still attributable to the relay.
  defp tag(result, config) do
    result
    |> Map.from_struct()
    |> Map.put(:provider_id, config.id)
    |> Map.put(:provider_type, config.type)
    |> Map.put(:provider_name, result.origin || config.name)
    |> Map.put(:provider_priority, config.priority || 0)
  end

  # Sort by priority before deduping so the operator's preferred provider is the
  # copy that survives. Note this only catches a provider repeating itself and
  # providers that happen to agree on a hash. Gestdown returns no hash at all,
  # and the synthesized fallback hash is derived from a provider-specific file
  # id, so the same subtitle from two providers legitimately arrives twice.
  defp dedupe(results) do
    results
    |> Enum.sort_by(& &1.provider_priority, :desc)
    |> Enum.reduce({[], MapSet.new()}, fn result, {kept, seen} ->
      key = dedupe_key(result)

      if MapSet.member?(seen, key) do
        {kept, seen}
      else
        {[result | kept], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp dedupe_key(%{subtitle_hash: hash}) when is_binary(hash) and hash != "", do: hash
  defp dedupe_key(%{file_id: file_id, language: language}), do: {file_id, language}

  defp status(config, error) do
    %{
      name: config.name,
      quota_remaining: Map.get(config, :quota_remaining),
      quota_total: Map.get(config, :quota_total),
      error: error
    }
  end

  defp describe(:quota_exceeded), do: "Daily quota exhausted"
  defp describe(:rate_limited), do: "Rate limited, try again shortly"
  defp describe(:invalid_credentials), do: "Credentials rejected"
  defp describe(:timeout), do: "The provider did not respond in time"
  defp describe({:crashed, _reason}), do: "The provider failed unexpectedly"
  defp describe({:transport, _reason}), do: "Could not reach the provider"

  defp describe(:metadata_relay_not_configured),
    do: "Subtitle search is not configured. Set a metadata relay URL or add a provider."

  defp describe(:service_unavailable),
    do:
      "The subtitle provider is unavailable. A self-hosted relay needs OpenSubtitles credentials."

  defp describe(reason), do: "Search failed: #{inspect(reason)}"
end
