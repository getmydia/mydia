defmodule Mydia.Downloads.Client.Debrid.Provider do
  @moduledoc """
  Internal behaviour shared by every debrid provider module
  (Real-Debrid, AllDebrid, Premiumize, TorBox).

  The public dispatch lives in `Mydia.Downloads.Client.Debrid`, which selects
  the right provider module via `config.connection_settings["provider"]` and
  forwards each call. The behaviour models the conceptually-identical
  pipeline shared by all four services:

      submit_torrent → post_submission_setup → get_job/list_jobs →
      get_download_urls → delete_job

  ## Test seam

  Internal tests inject a hand-rolled stub provider module (see
  `test/support/`) for the dispatch tests in `Mydia.Downloads.Client.DebridTest`.
  """

  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Structs.ClientInfo

  @typedoc """
  Config passed through from `Mydia.Downloads.Client` — see the parent
  behaviour for the canonical shape. Provider modules read `:api_key` and,
  occasionally, fields under `:connection_settings`.
  """
  @type config :: map()

  @typedoc """
  Provider-side job/torrent identifier returned by `submit_torrent/2`,
  stored as `Download.download_client_id`.
  """
  @type provider_job_id :: String.t()

  @typedoc """
  Torrent input forwarded by the dispatch adapter. NZB rejection happens
  upstream in `Debrid.add_torrent/3`.
  """
  @type torrent_input :: {:magnet, String.t()} | {:file, binary()}

  @typedoc """
  Either a plain HTTPS URL (RD/AD/PM) or a tokenless capability descriptor
  (TorBox), as documented in the plan's R8 section. Persisted into
  `Download.metadata["debrid_urls"]` by the adapter.
  """
  @type download_url ::
          String.t()
          | %{required(String.t()) => term()}

  @doc """
  Validates the operator's credentials and confirms the account has the
  capability needed to submit releases (premium status, etc.).
  """
  @callback validate_credentials(config()) :: {:ok, ClientInfo.t()} | {:error, Error.t()}

  @doc """
  Submits a release to the provider. Returns the provider-side identifier.
  """
  @callback submit_torrent(config(), torrent_input()) ::
              {:ok, provider_job_id()} | {:error, Error.t()}

  @doc """
  Optional post-submission setup step. Real-Debrid requires this to call
  `/torrents/selectFiles/{id}` with `files=all`; the other providers leave
  it as a no-op (default behaviour via `@optional_callbacks`).
  """
  @callback post_submission_setup(config(), provider_job_id()) :: :ok | {:error, Error.t()}

  @doc """
  Fetches a single job's current state. Used by non-cron callers
  (`queue/client_selection.ex` re-queue verify, `media_import/discovery.ex` save_path resolve).
  """
  @callback get_job(config(), provider_job_id()) :: {:ok, ProviderJob.t()} | {:error, Error.t()}

  @doc """
  Batch fetch for the cron polling seam. Providers with native batch
  endpoints (AD/PM/TB) issue one HTTP call; Real-Debrid falls back to
  N concurrent `get_job/2` calls under the rate limiter (see
  `Mydia.Downloads.Client.Debrid.Providers.RealDebrid.list_jobs/2`).

  Returns a map keyed by `provider_job_id`. Missing IDs are simply absent
  from the map — callers must tolerate them.
  """
  @callback list_jobs(config(), [provider_job_id()]) ::
              {:ok, %{provider_job_id() => ProviderJob.t()}} | {:error, Error.t()}

  @doc """
  Resolves the provider's hoster links into URLs (or tokenless descriptors
  in TorBox's case) suitable for the per-download `Fetcher` to stream into
  staging. Called once per `:ready` job that doesn't yet have a Fetcher
  registered.
  """
  @callback get_download_urls(config(), ProviderJob.t()) ::
              {:ok, [download_url()]} | {:error, Error.t()}

  @doc """
  Removes the job from the provider, best-effort. The dispatch adapter
  treats `:not_found` as success.
  """
  @callback delete_job(config(), provider_job_id()) :: :ok | {:error, Error.t()}

  @doc """
  Per-token request budget surfaced to
  `Mydia.Downloads.Client.Debrid.RateLimiter`. Returned as
  `{requests, per_seconds}`.
  """
  @callback rate_limit_budget() :: {pos_integer(), pos_integer()}

  @optional_callbacks post_submission_setup: 2

  @doc """
  Provider-string-to-module map used by the dispatch adapter.

  Honors `Application.get_env(:mydia, :debrid_provider_overrides, %{})`
  first so tests can inject a stub module per provider key without
  touching the production lookup table.
  """
  @spec module_for(String.t()) :: {:ok, module()} | {:error, Error.t()}
  def module_for(key) when is_binary(key) do
    overrides = Application.get_env(:mydia, :debrid_provider_overrides, %{})

    case Map.fetch(overrides, key) do
      {:ok, module} when is_atom(module) -> {:ok, module}
      :error -> default_module_for(key)
    end
  end

  defp default_module_for("real_debrid"),
    do: {:ok, Mydia.Downloads.Client.Debrid.Providers.RealDebrid}

  defp default_module_for("all_debrid"),
    do: {:ok, Mydia.Downloads.Client.Debrid.Providers.AllDebrid}

  defp default_module_for("premiumize"),
    do: {:ok, Mydia.Downloads.Client.Debrid.Providers.Premiumize}

  defp default_module_for("tor_box"),
    do: {:ok, Mydia.Downloads.Client.Debrid.Providers.TorBox}

  defp default_module_for(other) do
    {:error,
     Error.invalid_config(
       "unknown debrid provider: #{inspect(other)} " <>
         "(must be one of: real_debrid, all_debrid, premiumize, tor_box)"
     )}
  end

  @doc """
  Human-readable label per provider key. Used in `ClientInfo.version` and
  error messages.
  """
  @spec label_for(String.t()) :: String.t()
  def label_for("real_debrid"), do: "Real-Debrid"
  def label_for("all_debrid"), do: "AllDebrid"
  def label_for("premiumize"), do: "Premiumize"
  def label_for("tor_box"), do: "TorBox"
  def label_for(other), do: "Unknown (#{inspect(other)})"

  @doc """
  Returns the provider key configured on a given client config.

  Defensive against missing or invalid configuration — returns an error
  rather than crashing.
  """
  @spec provider_key(config()) :: {:ok, String.t()} | {:error, Error.t()}
  def provider_key(%{connection_settings: %{"provider" => provider}})
      when is_binary(provider) do
    {:ok, provider}
  end

  def provider_key(_) do
    {:error, Error.invalid_config("debrid config is missing connection_settings[\"provider\"]")}
  end
end
