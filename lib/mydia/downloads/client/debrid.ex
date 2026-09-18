defmodule Mydia.Downloads.Client.Debrid do
  @moduledoc """
  Public debrid download-client adapter.

  Implements the `Mydia.Downloads.Client` behaviour as a thin dispatcher
  to per-provider modules (Real-Debrid, AllDebrid, Premiumize, TorBox).
  The provider is selected per-config via
  `config.connection_settings["provider"]`; an operator who wants two
  providers configures two `:debrid` client rows.

  ## Polling seam

  `list_torrents/2` is the primary cron polling seam, invoked once per
  configured client per `DownloadMonitor` tick from
  `Mydia.Downloads.History.fetch_all_client_statuses/1`. Inside this call
  the adapter does its provider state synthesis, R8 URL persistence, and
  Fetcher claim.

  `get_status/2` is the synchronous variant for the two non-cron callers
  (`queue.ex` re-queue verify, `media_import.ex` save_path resolve). It
  does NOT persist R8 or start the Fetcher — those flows belong to the
  cron path.

  ## R8 (Download.metadata["debrid_urls"]) shape

  Per the plan's key technical decision, the persisted shape varies by
  provider:

  - RD/AD/PM: each entry is `%{"url" => https_url, "resolved_at" => iso8601}`
  - TorBox:   each entry is `%{"provider" => "torbox", "torrent_id" => N, "file_id" => N}`

  TorBox descriptors are tokenless on purpose — the operator's API token
  is appended at fetch time from `config.api_key`. This guarantees that
  a DB dump never exposes the token via URL query strings.
  """

  @behaviour Mydia.Downloads.Client

  @impl true
  def supported_protocols, do: [:torrent]

  require Logger

  alias Mydia.Downloads.Client.Debrid.{Fetcher, Provider, RateLimiter, Shared}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Structs.ClientInfo
  alias Mydia.Downloads.{Download, History}
  alias Mydia.Repo
  import Ecto.Query, only: [from: 2]

  ## ── Behaviour callbacks ──────────────────────────────────────────────

  @impl true
  def test_connection(config) do
    with {:ok, provider_module, provider_atom, provider_key} <- resolve_provider(config),
         :ok <- acquire(provider_atom, config),
         {:ok, info} <- provider_module.validate_credentials(config) do
      label = Provider.label_for(provider_key)

      {:ok,
       %ClientInfo{
         version: "Debrid (#{label}) — #{info.version || "ok"}",
         api_version: info.api_version
       }}
    else
      {:error, %Error{} = err} -> {:error, sanitize_error(err, config)}
      {:error, other} -> {:error, sanitize_error(other, config)}
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    case torrent do
      {:file, bin} when is_binary(bin) ->
        if looks_like_nzb?(bin) do
          {:error, Error.invalid_torrent("NZB content cannot be submitted to a debrid client")}
        else
          do_add(config, {:file, bin}, opts)
        end

      {:magnet, _magnet} = input ->
        do_add(config, input, opts)

      {:url, url} when is_binary(url) ->
        with {:ok, validated} <- Shared.validate_download_url(url),
             {:ok, bin} <- fetch_torrent_bytes(validated) do
          add_torrent(config, {:file, bin}, opts)
        end

      _ ->
        {:error, Error.invalid_torrent("unsupported torrent input shape")}
    end
  end

  @impl true
  def get_status(config, client_id) do
    with {:ok, provider_module, provider_atom, _key} <- resolve_provider(config),
         :ok <- acquire(provider_atom, config),
         {:ok, job} <- provider_module.get_job(config, client_id) do
      # Look up the Mydia Download by client_id so synthesize_status sees
      # save_path / bytes_pulled from metadata. MediaImport's
      # `get_download_files/2` falls back to args.save_path ONLY when
      # `get_status` returns `{:error, _}` — if we return `{:ok, status}`
      # with `status.save_path == nil`, it treats it as a hard `:no_save_path`
      # failure and never tries the fallback. Loading the Download here
      # closes that gap and lets the cron-driven completion flow work.
      download = lookup_download_by_client_id(client_id)

      status =
        Shared.synthesize_status(
          job,
          fetcher_state(download && download.id, download),
          download
        )

      {:ok, status}
    else
      {:error, %Error{} = err} -> {:error, sanitize_error(err, config)}
      {:error, other} -> {:error, sanitize_error(other, config)}
    end
  end

  defp lookup_download_by_client_id(client_id) when is_binary(client_id) do
    import Ecto.Query

    Mydia.Downloads.Download
    |> where([d], d.download_client_id == ^client_id)
    |> limit(1)
    |> Mydia.Repo.one()
  rescue
    _ -> nil
  end

  defp lookup_download_by_client_id(_), do: nil

  @impl true
  def list_torrents(config, opts \\ []) do
    case Keyword.get(opts, :downloads) do
      downloads when is_map(downloads) and map_size(downloads) > 0 ->
        do_list_torrents(config, downloads)

      _ ->
        # No downloads passed (untracked-matcher path) — debrid downloads
        # have no concept of "untracked on the client" so we return empty.
        {:ok, []}
    end
  end

  @impl true
  def remove_torrent(config, client_id, _opts \\ []) do
    # Terminate any running Fetcher for this download before deleting the
    # provider-side job. We look up the Mydia download by client_id so
    # that callers don't need to plumb the internal download_id through.
    terminate_fetcher_for_client_id(client_id)

    with {:ok, provider_module, provider_atom, _key} <- resolve_provider(config),
         :ok <- acquire(provider_atom, config),
         :ok <- best_effort_provider_delete(provider_module, config, client_id) do
      :ok
    else
      {:error, %Error{} = err} -> {:error, sanitize_error(err, config)}
    end
  end

  @impl true
  def pause_torrent(_config, client_id) do
    Logger.debug(
      "Debrid adapter received pause_torrent for #{client_id} — no-op (providers don't expose pause)"
    )

    :ok
  end

  @impl true
  def resume_torrent(_config, client_id) do
    Logger.debug(
      "Debrid adapter received resume_torrent for #{client_id} — no-op (providers don't expose resume)"
    )

    :ok
  end

  ## ── Internal: list_torrents flow ─────────────────────────────────────

  defp do_list_torrents(config, downloads_by_client_id) do
    with {:ok, provider_module, provider_atom, _key} <- resolve_provider(config),
         :ok <- acquire(provider_atom, config),
         {:ok, jobs} <-
           provider_module.list_jobs(config, Map.keys(downloads_by_client_id)) do
      statuses =
        jobs
        |> Enum.map(fn {client_id, job} ->
          download = Map.get(downloads_by_client_id, client_id)
          maybe_persist_and_claim(provider_module, provider_atom, config, job, download)

          Shared.synthesize_status(
            job,
            fetcher_state(download && download.id, download),
            download
          )
        end)

      {:ok, statuses}
    else
      {:error, %Error{} = err} -> {:error, sanitize_error(err, config)}
      {:error, other} -> {:error, sanitize_error(other, config)}
    end
  end

  defp maybe_persist_and_claim(provider_module, provider_atom, config, job, download)

  defp maybe_persist_and_claim(_pm, _pa, _config, _job, nil), do: :ok

  defp maybe_persist_and_claim(provider_module, provider_atom, config, job, download) do
    cond do
      job.state != :ready ->
        :ok

      fetcher_already_running?(download.id) ->
        :ok

      already_completed?(download) ->
        :ok

      true ->
        persist_r8_and_claim(provider_module, provider_atom, config, job, download)
    end
  end

  defp persist_r8_and_claim(provider_module, provider_atom, config, job, download) do
    with :ok <- acquire(provider_atom, config),
         {:ok, urls_or_descriptors} <- provider_module.get_download_urls(config, job),
         {:ok, validated} <- validate_r8_urls(urls_or_descriptors) do
      persisted = build_r8(provider_module, validated)
      merge_metadata!(download, %{"debrid_urls" => persisted})

      # If a previous cron tick stamped an error_message (e.g. transient
      # rate-limit), clear it now that we've successfully resolved URLs.
      maybe_clear_download_error(download)

      _ =
        Fetcher.claim(
          download_id: download.id,
          config: config,
          provider_job: job,
          provider_module: provider_module,
          prefetched_urls: validated
        )

      :ok
    else
      {:error, err} ->
        sanitized = sanitize_error(err, config)

        Logger.warning(
          "Debrid (#{provider_atom}) failed to resolve URLs for download " <>
            "#{download.id}: #{inspect(sanitized)}"
        )

        # Surface the failure to the operator. Without this, the downloads
        # page sees a `:ready` provider state with no save_path and shows
        # the synthesized `:queued` state with no indication of *why* nothing
        # is progressing. Writing to `error_message` makes the failure
        # visible in the UI alongside the queued badge.
        record_download_error(download, error_message_for(sanitized))

        :error
    end
  end

  defp record_download_error(download, message) do
    case Mydia.Downloads.History.update_download(download, %{error_message: message}) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  rescue
    _ -> :ok
  end

  # Clear an `error_message` we previously stamped (prefixed "Debrid: ").
  # Avoids wiping diagnostics set by other code paths.
  defp maybe_clear_download_error(%Mydia.Downloads.Download{error_message: msg} = download)
       when is_binary(msg) do
    if String.starts_with?(msg, "Debrid: ") do
      Mydia.Downloads.History.update_download(download, %{error_message: nil})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp maybe_clear_download_error(_), do: :ok

  defp error_message_for(%Error{message: msg, details: %{reason: reason}})
       when is_atom(reason),
       do: "Debrid: #{msg} (#{reason})"

  defp error_message_for(%Error{message: msg}), do: "Debrid: #{msg}"
  defp error_message_for(other), do: "Debrid: #{inspect(other)}"

  # Validates all HTTPS URLs from the provider before persisting them.
  # Descriptors (TorBox tokenless entries) are passed through as-is since
  # their eventual URL is constructed at fetch-time, where validation happens.
  defp validate_r8_urls(urls_or_descriptors) do
    Enum.reduce_while(urls_or_descriptors, {:ok, []}, fn
      %{"provider" => _} = descriptor, {:ok, acc} ->
        {:cont, {:ok, [descriptor | acc]}}

      url, {:ok, acc} when is_binary(url) ->
        case Shared.validate_download_url(url) do
          {:ok, validated_url} -> {:cont, {:ok, [validated_url | acc]}}
          {:error, _} = err -> {:halt, err}
        end

      other, {:ok, acc} ->
        {:cont, {:ok, [other | acc]}}
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp build_r8(provider_module, urls_or_descriptors) do
    Enum.map(urls_or_descriptors, fn
      url when is_binary(url) ->
        %{"url" => url, "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601()}

      %{"provider" => _} = descriptor ->
        # TorBox tokenless descriptor — passthrough.
        descriptor

      other ->
        Logger.warning(
          "Debrid (#{inspect(provider_module)}) returned unrecognised URL/descriptor: " <>
            inspect(other)
        )

        %{"raw" => inspect(other)}
    end)
  end

  defp merge_metadata!(download, new_keys) do
    History.update_download(download, %{
      metadata: Map.merge(download.metadata || %{}, new_keys)
    })
  end

  defp fetcher_already_running?(download_id) do
    match?({:ok, _pid}, Fetcher.whereis(download_id))
  end

  defp already_completed?(download) do
    case download do
      %{metadata: %{"save_path" => path}} when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp fetcher_state(nil, _download), do: :not_started

  defp fetcher_state(download_id, download) do
    cond do
      fetcher_already_running?(download_id) -> :running
      download && already_completed?(download) -> :completed
      true -> :not_started
    end
  end

  ## ── Internal: add flow ───────────────────────────────────────────────

  defp do_add(config, input, _opts) do
    with {:ok, provider_module, provider_atom, _key} <- resolve_provider(config),
         :ok <- acquire(provider_atom, config),
         {:ok, provider_job_id} <- provider_module.submit_torrent(config, input),
         :ok <- maybe_post_submission_setup(provider_module, config, provider_job_id) do
      {:ok, provider_job_id}
    else
      {:error, %Error{} = err} -> {:error, sanitize_error(err, config)}
      {:error, other} -> {:error, sanitize_error(other, config)}
    end
  end

  defp maybe_post_submission_setup(provider_module, config, provider_job_id) do
    if function_exported?(provider_module, :post_submission_setup, 2) do
      case provider_module.post_submission_setup(config, provider_job_id) do
        :ok -> :ok
        {:error, _} = err -> err
      end
    else
      :ok
    end
  end

  defp fetch_torrent_bytes(url) do
    case Req.get(url) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, IO.iodata_to_binary([body])}

      {:ok, resp} ->
        {:error, Error.from_req_error(resp)}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}
    end
  end

  defp best_effort_provider_delete(provider_module, config, client_id) do
    case provider_module.delete_job(config, client_id) do
      :ok ->
        :ok

      {:error, %Error{type: :not_found}} ->
        # Already gone — fine.
        :ok

      {:error, _} = err ->
        err
    end
  end

  ## ── Helpers ──────────────────────────────────────────────────────────

  defp resolve_provider(config) do
    with {:ok, key} <- Provider.provider_key(config),
         {:ok, module} <- Provider.module_for(key) do
      {:ok, module, provider_atom_for_key(key), key}
    end
  end

  defp provider_atom_for_key("real_debrid"), do: :real_debrid
  defp provider_atom_for_key("all_debrid"), do: :all_debrid
  defp provider_atom_for_key("premiumize"), do: :premiumize
  defp provider_atom_for_key("tor_box"), do: :tor_box
  defp provider_atom_for_key(_), do: :unknown

  defp acquire(provider_atom, config) do
    budget = budget_for(provider_atom)
    api_key = api_key_of(config)

    case RateLimiter.acquire(provider_atom, api_key, budget) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, rate_limited_error(provider_atom)}
    end
  end

  defp budget_for(:real_debrid), do: {250, 60}
  defp budget_for(:all_debrid), do: {600, 60}
  defp budget_for(:premiumize), do: {30, 60}
  defp budget_for(:tor_box), do: {300, 60}
  defp budget_for(_), do: {1000, 60}

  defp api_key_of(%{api_key: key}) when is_binary(key), do: key
  defp api_key_of(%{api_key: nil}), do: ""
  defp api_key_of(%{}), do: ""

  defp rate_limited_error(provider_atom) do
    Error.api_error("rate-limited by debrid provider", %{
      reason: :rate_limited,
      provider: provider_atom
    })
  end

  defp looks_like_nzb?(<<"<?xml", _::binary>>), do: true
  defp looks_like_nzb?(<<"<nzb", _::binary>>), do: true

  defp looks_like_nzb?(bin) when is_binary(bin) do
    bin
    |> binary_part(0, min(byte_size(bin), 1024))
    |> String.contains?("<nzb")
  end

  defp sanitize_error(%Error{details: nil} = err, _config), do: err

  defp sanitize_error(%Error{details: details} = err, config) do
    %{err | details: Shared.sanitize_error_body(details, config)}
  end

  defp sanitize_error(other, _config), do: other

  # Terminates any running Fetcher for a download identified by its
  # provider-side client_id. Best-effort — if no Fetcher is running or the
  # lookup fails, it is silently ignored.
  defp terminate_fetcher_for_client_id(client_id) do
    try do
      download_id =
        Repo.one(
          from(d in Download,
            where: d.download_client_id == ^client_id and d.download_client == "debrid",
            select: d.id,
            limit: 1
          )
        )

      if download_id, do: Fetcher.terminate(download_id)
    rescue
      _ -> :ok
    end
  end
end
