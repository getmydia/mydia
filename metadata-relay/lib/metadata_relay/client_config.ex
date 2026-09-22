defmodule MetadataRelay.ClientConfig do
  @moduledoc """
  The client configuration document served at `GET /client-config`.

  Installs read this at boot to learn which iroh relays mydia operates, so a
  relay can be added, moved or retired by changing this service's
  configuration instead of shipping a new server image and player build.

  The list comes from `CLIENT_CONFIG_RELAYS`, a comma-separated list of relay
  URLs read at boot by `config/runtime.exs`. In production it is set in the
  `metadata-relay-config` ConfigMap; the README's "Changing the relay list"
  has the steps. When it is unset, or any entry is invalid, the built-in list
  is served instead and `log_config/0` says why at boot.

  The relay-worker serves the same document from KV
  (`relay-worker/src/config/client_config.ts`), and
  `relay-worker/test/contract/routes.json` includes this route, so the cutover
  gate reports the two services being configured differently.

  Clients ignore keys they do not know, so a new key can be added here without
  a client change. There is deliberately no version field: an incompatible
  change adds a new key and leaves the old one in place for a release, which is
  the same shape as the `pairing/v2` fallback in the player's relay client.
  """

  require Logger

  @default_relay_urls ["https://cae1-1.relay.mydia.dev"]

  @doc """
  The relays served when `CLIENT_CONFIG_RELAYS` is unset or rejected.
  """
  @spec default_relay_urls() :: [String.t()]
  def default_relay_urls, do: @default_relay_urls

  @doc """
  The iroh relays mydia operates, in preference order.

  Clients append iroh's own public relays underneath these as a fallback, so
  this list carries only mydia's own.
  """
  @spec relay_urls() :: [String.t()]
  def relay_urls do
    case parse(configured()) do
      {:ok, urls} -> urls
      _unset_or_rejected -> @default_relay_urls
    end
  end

  @doc """
  The full client configuration document.
  """
  @spec document() :: %{p2p: %{relays: [String.t()]}}
  def document, do: %{p2p: %{relays: relay_urls()}}

  @doc """
  Parses a `CLIENT_CONFIG_RELAYS` value.

  Accepts a comma-separated list of distinct `https` URLs with a host, the
  rule installs apply in `Mydia.P2p.RelayList`, so this never serves a relay a
  client would discard. Blank entries (a trailing comma) are skipped. One bad
  entry rejects the whole value: a list with a relay silently dropped is
  harder to notice than one that falls back to the default and says why.
  """
  @spec parse(String.t() | nil) :: {:ok, [String.t()]} | :unset | {:error, String.t()}
  def parse(nil), do: :unset

  def parse(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        :unset

      trimmed ->
        trimmed
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> validate()
    end
  end

  @doc """
  Logs which relay list this instance serves, and why a configured value was
  rejected. Called once from `MetadataRelay.Application.start/2`; never
  raises, because a crash at boot would take the TMDB/TVDB proxy down with it.
  """
  @spec log_config() :: :ok
  def log_config do
    case parse(configured()) do
      {:ok, urls} ->
        Logger.info("CLIENT_CONFIG_RELAYS set, serving #{Enum.join(urls, ", ")}")

      :unset ->
        Logger.info("CLIENT_CONFIG_RELAYS not set, serving the built-in relay list")

      {:error, reason} ->
        Logger.warning(
          "CLIENT_CONFIG_RELAYS ignored (#{reason}), serving the built-in relay list"
        )
    end

    :ok
  end

  defp configured, do: Application.get_env(:metadata_relay, :client_config_relays)

  defp validate([]), do: {:error, "no relays listed"}

  defp validate(urls) do
    cond do
      bad = Enum.find(urls, &(not https_with_host?(&1))) ->
        {:error, "#{inspect(bad)} is not an https URL with a host"}

      dup = List.first(urls -- Enum.uniq(urls)) ->
        {:error, "#{inspect(dup)} is listed twice"}

      true ->
        {:ok, urls}
    end
  end

  defp https_with_host?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      _ -> false
    end
  end
end
