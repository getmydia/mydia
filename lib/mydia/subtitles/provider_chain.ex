defmodule Mydia.Subtitles.ProviderChain do
  @moduledoc """
  Walks a user's enabled subtitle providers by priority.

  A fresh install has no provider rows and must still work, so an empty list
  synthesizes the relay. A provider that errors — out of quota, unreachable,
  rate limited, anything — is recorded and the walk continues, which is the
  whole point of having a chain: the relay's OpenSubtitles account is shared
  across every Mydia install, and a user who exhausts it (or hits any other
  transient failure) should fall through to the next provider, including
  their own.

  Two contracts matter here and are easy to get backwards:

    * Every error from a provider's `search/2`, not just `:quota_exceeded`,
      must be recorded and walked past. `Provider.Relay.search/2` itself can
      never return `:quota_exceeded` (only its `download/2` can), so a chain
      that only advanced past quota errors would stop dead on the relay's
      ordinary failures and never reach a user's own provider.
    * `quota_info/1` is never consulted to decide whether to try a provider.
      `Provider.Relay.quota_info/1` always reports `:unlimited` by design —
      the shared account's real quota is deliberately invisible — while its
      `search/2`/`download/2` can still fail with `:quota_exceeded` when that
      shared account hits its ceiling. The only source of truth for whether a
      provider is usable right now is the error (or lack of one) its own
      `search/2` call returns.
  """

  require Logger

  alias Mydia.Subtitles.Providers

  @relay_default %{
    id: "relay-default",
    name: "Mydia Relay",
    type: :relay,
    enabled: true,
    priority: 0
  }

  @doc """
  Returns the provider used when a user has configured none.
  """
  @spec default_provider() :: map()
  def default_provider, do: @relay_default

  @doc """
  Returns the adapter module for a provider.
  """
  @spec adapter_for(map()) :: module()
  def adapter_for(provider) do
    case Application.get_env(:mydia, :subtitle_adapter_override) do
      nil -> adapter_by_type(provider.type)
      override -> override
    end
  end

  defp adapter_by_type(:relay), do: Mydia.Subtitles.Provider.Relay
  defp adapter_by_type(:opensubtitles), do: Mydia.Subtitles.Provider.OpenSubtitles

  @doc """
  Searches every enabled provider in priority order.
  """
  @spec search(binary() | nil, map()) :: {:ok, %{results: [map()], providers: [map()]}}
  def search(user_id, params) do
    providers = enabled_providers(user_id)

    {results, statuses} =
      Enum.reduce(providers, {[], []}, fn provider, {results_acc, status_acc} ->
        case run_search(provider, params) do
          {:ok, provider_results} ->
            tagged = Enum.map(provider_results, &tag(&1, provider))
            {results_acc ++ tagged, status_acc ++ [status(provider, nil)]}

          {:error, reason} ->
            Logger.warning("Subtitle provider search failed",
              provider: provider.name,
              reason: inspect(reason)
            )

            {results_acc, status_acc ++ [status(provider, describe(reason))]}
        end
      end)

    {:ok, %{results: dedupe(results), providers: statuses}}
  end

  ## Private

  defp enabled_providers(nil), do: [@relay_default]

  defp enabled_providers(user_id) do
    case Providers.list_enabled_providers(user_id) do
      [] -> [@relay_default]
      providers -> providers
    end
  end

  defp run_search(provider, params) do
    adapter_for(provider).search(provider, params)
  rescue
    e -> {:error, e}
  end

  defp tag(result, provider) do
    result
    |> Map.from_struct()
    |> Map.put(:provider_id, provider.id)
    |> Map.put(:provider_name, provider.name)
  end

  # Earlier providers win, because the list is already in priority order.
  defp dedupe(results) do
    results
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

  defp status(provider, error) do
    %{
      name: provider.name,
      quota_remaining: Map.get(provider, :quota_remaining),
      quota_total: Map.get(provider, :quota_total),
      error: error
    }
  end

  defp describe(:quota_exceeded), do: "Daily quota exhausted"
  defp describe(:rate_limited), do: "Rate limited, try again shortly"
  defp describe(:invalid_credentials), do: "Credentials rejected"
  defp describe({:transport, _reason}), do: "Could not reach the provider"
  defp describe(reason), do: "Search failed: #{inspect(reason)}"
end
