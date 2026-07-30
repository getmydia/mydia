defmodule Mydia.Downloads.Client.Debrid.Shared do
  @moduledoc """
  Shared helpers used by all debrid provider modules and by the public
  `Mydia.Downloads.Client.Debrid` dispatch adapter.

  Three responsibility clusters:

    * **State mapping**: `synthesize_status/3` turns a `ProviderJob` plus
      fetcher-side state plus the `Download` record into the canonical
      `DownloadStatus` consumed by `History` and `DownloadMonitor`.
    * **Error mapping**: `map_error/2` collapses per-provider error codes
      into `Mydia.Downloads.Client.Error` types. Each provider also has
      its own per-code translation table; this module covers the cases
      shared across all four.
    * **Security primitives**: `redact_url/1` (delegated to
      `Mydia.Downloads.Client.Helpers`), `validate_download_url/1`, and
      `sanitize_error_body/2`.
  """

  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Structs.DownloadStatus

  # JSON object keys we drop entirely from response bodies before they
  # land in `Error.details`. Lowercased comparison.
  @sensitive_body_keys ~w(apikey api_key token agent auth authorization _apikey password)

  # Hosts we refuse to fetch from regardless of provider claim. SSRF
  # defense — a compromised provider could otherwise have us request its
  # own internal infrastructure.
  # Tuples are {octet1, octet2, octet3, prefix_bits}. The fourth element is
  # the CIDR prefix length, not the third octet — getting this wrong with
  # `prefix=0` causes `matches_prefix?/3` to compare zero bits, which
  # tautologically matches every IP (including public ones), bricking the
  # SSRF guard for legitimate provider CDNs (RD's chi3-4.download.real-debrid.com
  # was a real-world casualty).
  @rfc1918_patterns [
    {127, 0, 0, 8},
    {10, 0, 0, 8},
    {172, 16, 0, 12},
    {192, 168, 0, 16},
    {169, 254, 0, 16},
    {0, 0, 0, 8}
  ]

  # ── URL safety ────────────────────────────────────────────────────────

  @doc """
  Strips credential-bearing query parameters from a URL.

  Delegated to `Mydia.Downloads.Client.Helpers` — `failure_detail`
  sanitisation needs the same redaction from adapters that have no business
  reaching into the debrid namespace, so the implementation lives with the
  adapter-agnostic helpers. Kept here as a delegate because the four call
  sites in this module and the provider modules all reference it unqualified.
  """
  defdelegate redact_url(url), to: Helpers

  @doc """
  Enforces that a provider-returned URL is HTTPS and not pointing at
  RFC1918 / link-local space. Defense-in-depth against SSRF in case a
  provider gets compromised or its admin panel returns a malicious URL.

  Returns the URL unchanged on success so callers can pipe through it:

      with {:ok, url} <- Shared.validate_download_url(url),
           {:ok, _} <- Req.get(url, into: ...) do
        ...
      end
  """
  @spec validate_download_url(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_download_url(url) when is_binary(url) do
    if relaxed_url_validation?() do
      relaxed_validate(url)
    else
      strict_validate(url)
    end
  end

  defp strict_validate(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme not in ["https"] ->
        {:error,
         Error.api_error("non-HTTPS URL refused", %{
           reason: :non_https,
           url: redact_url(url)
         })}

      %URI{host: host} when host in [nil, ""] ->
        {:error,
         Error.api_error("URL missing host", %{reason: :missing_host, url: redact_url(url)})}

      %URI{host: host} = parsed ->
        if private_host?(host) do
          {:error,
           Error.api_error("private/link-local host refused", %{
             reason: :private_host,
             host: host
           })}
        else
          {:ok, URI.to_string(parsed)}
        end
    end
  end

  # Only enabled inside the test environment when explicitly opted in. Keeps
  # the SSRF guard intact for production while letting Fetcher tests drive
  # the GenServer against `Bypass`-served `http://127.0.0.1:PORT` URLs.
  defp relaxed_validate(url) do
    case URI.parse(url) do
      %URI{scheme: nil} ->
        {:error,
         Error.api_error("URL missing scheme", %{reason: :missing_scheme, url: redact_url(url)})}

      %URI{host: host} when host in [nil, ""] ->
        {:error,
         Error.api_error("URL missing host", %{reason: :missing_host, url: redact_url(url)})}

      uri ->
        {:ok, URI.to_string(uri)}
    end
  end

  defp relaxed_url_validation? do
    Application.get_env(:mydia, :debrid_relaxed_url_validation, false) == true
  end

  @doc """
  Returns true if the host is RFC1918, loopback, link-local, or otherwise
  on the SSRF blocklist.
  """
  @spec private_host?(String.t()) :: boolean()
  def private_host?(host) when is_binary(host) do
    cond do
      host == "" -> true
      host in ["localhost", "::1", "[::1]"] -> true
      true -> private_ip_or_hostname?(host)
    end
  end

  defp private_ip_or_hostname?(host) do
    # Strip brackets from IPv6 URL notation (e.g., "[::1]" → "::1")
    host_stripped =
      if String.starts_with?(host, "[") and String.ends_with?(host, "]") do
        String.slice(host, 1, byte_size(host) - 2)
      else
        host
      end

    case :inet.parse_address(to_charlist(host_stripped)) do
      {:ok, {a, b, c, d}} ->
        ipv4_in_blocklist?({a, b, c, d})

      {:ok, ipv6_tuple} when tuple_size(ipv6_tuple) == 8 ->
        ipv6_in_blocklist?(ipv6_tuple)

      _ ->
        # Not a raw IP literal — attempt DNS resolution to catch
        # hostnames that point at RFC1918 / link-local addresses.
        # Fail *open* on resolution errors (DNS unavailable, timeout)
        # so valid provider CDNs are not blocked by transient DNS issues.
        resolve_and_check(host_stripped)
    end
  end

  defp resolve_and_check(host) do
    # Check both IPv4 and IPv6 resolution to cover all RFC1918/link-local cases.
    case :inet.getaddr(to_charlist(host), :inet) do
      {:ok, {a, b, c, d}} ->
        ipv4_in_blocklist?({a, b, c, d})

      _ ->
        case :inet.getaddr(to_charlist(host), :inet6) do
          {:ok, ipv6_tuple} when tuple_size(ipv6_tuple) == 8 ->
            ipv6_in_blocklist?(ipv6_tuple)

          _ ->
            false
        end
    end
  end

  defp ipv4_in_blocklist?({a, b, _c, _d} = ip) do
    Enum.any?(@rfc1918_patterns, fn {p1, p2, p3, prefix} ->
      case prefix do
        # 0-bit prefix tautologically matches everything — refuse it so a
        # mistyped pattern can never accidentally reject public traffic.
        0 -> false
        8 -> a == p1
        16 -> a == p1 and b == p2
        12 -> a == p1 and Bitwise.band(b, 0xF0) == Bitwise.band(p2, 0xF0)
        _ -> matches_prefix?(ip, {p1, p2, p3, 0}, prefix)
      end
    end)
  end

  # ULA: fc00::/7 — top 7 bits 1111110x → (a & 0xFE00) == 0xFC00.
  # Link-local: fe80::/10 — top 10 bits 1111111010 → (a & 0xFFC0) == 0xFE80.
  defp ipv6_in_blocklist?({a, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      Bitwise.band(a, 0xFE00) == 0xFC00 -> true
      Bitwise.band(a, 0xFFC0) == 0xFE80 -> true
      true -> false
    end
  end

  defp matches_prefix?({a, b, c, d}, {p1, p2, p3, p4}, prefix) do
    bits =
      <<a::8, b::8, c::8, d::8>>
      |> :binary.bin_to_list()

    pbits =
      <<p1::8, p2::8, p3::8, p4::8>>
      |> :binary.bin_to_list()

    Enum.take(bits, div(prefix, 8)) == Enum.take(pbits, div(prefix, 8))
  end

  # ── Response sanitization ─────────────────────────────────────────────

  @doc """
  Recursively scrubs sensitive keys from a JSON-shaped response body and
  redacts literal occurrences of the config's API key in string fields.

  Provider modules wrap this around the response body before constructing
  any `Error.details`, so credentials never reach logs or DB rows even
  when the provider echoes them in error messages (Premiumize is a known
  offender).
  """
  @spec sanitize_error_body(term(), %{optional(:api_key) => String.t() | nil}) :: term()
  def sanitize_error_body(body, config) when is_map(config) do
    api_key = Map.get(config, :api_key)
    do_sanitize(body, api_key)
  end

  def sanitize_error_body(body, _), do: do_sanitize(body, nil)

  defp do_sanitize(map, api_key) when is_map(map) do
    Enum.reduce(map, %{}, fn {k, v}, acc ->
      if sensitive_key?(k) do
        acc
      else
        Map.put(acc, k, do_sanitize(v, api_key))
      end
    end)
  end

  defp do_sanitize(list, api_key) when is_list(list) do
    Enum.map(list, &do_sanitize(&1, api_key))
  end

  defp do_sanitize(value, api_key) when is_binary(value) do
    redact_api_key_literal(value, api_key)
  end

  defp do_sanitize(value, _), do: value

  defp sensitive_key?(key) when is_atom(key) do
    sensitive_key?(Atom.to_string(key))
  end

  defp sensitive_key?(key) when is_binary(key) do
    String.downcase(key) in @sensitive_body_keys
  end

  defp sensitive_key?(_), do: false

  defp redact_api_key_literal(value, nil), do: value
  defp redact_api_key_literal(value, ""), do: value

  defp redact_api_key_literal(value, api_key)
       when is_binary(value) and is_binary(api_key) do
    String.replace(value, api_key, "[REDACTED]")
  end

  defp redact_api_key_literal(value, _), do: value

  # ── Error mapping ─────────────────────────────────────────────────────

  @doc """
  Generic provider-error fallback. Most provider modules implement their
  own per-code translation table and only call this for unknown codes.
  """
  @spec map_error(atom(), term()) :: Error.t()
  def map_error(provider, raw) do
    Error.api_error("unhandled #{provider} error", %{provider: provider, raw: raw})
  end

  # ── Canonical state synthesis ─────────────────────────────────────────

  @doc """
  Turns a `ProviderJob` and a fetcher snapshot into the canonical
  `DownloadStatus` consumed by `History` and `DownloadMonitor`.

  `fetcher_state` is one of `:not_started | :running | :completed | :failed`.
  `download` may be `nil` for the synchronous `get_status/2` path where
  the caller doesn't have the row loaded.
  """
  @spec synthesize_status(ProviderJob.t(), fetcher_state, Download.t() | nil) ::
          DownloadStatus.t()
        when fetcher_state: :not_started | :running | :completed | :failed
  def synthesize_status(%ProviderJob{} = job, fetcher_state, download) do
    base = base_status(job, download)
    apply_state(base, job, fetcher_state, download)
  end

  defp base_status(%ProviderJob{} = job, download) do
    save_path =
      case download do
        %Download{metadata: %{"save_path" => path}} when is_binary(path) -> path
        _ -> nil
      end

    %DownloadStatus{
      id: job.provider_id,
      name: job.name || "",
      state: :unknown,
      progress: clamped_progress(job.progress),
      download_speed: 0,
      upload_speed: 0,
      downloaded: 0,
      uploaded: 0,
      size: job.total_bytes || 0,
      eta: nil,
      ratio: 0.0,
      save_path: save_path,
      added_at: nil,
      completed_at: nil
    }
  end

  # The debrid lifecycle has TWO download phases the operator cares about:
  # the provider's own download from the swarm (we have no local copy yet)
  # and Mydia's local pull from the provider's CDN. Mirroring the provider's
  # progress while the local pull hasn't started would show "Downloading 100%"
  # on a torrent that has no local bytes — misleading. The mapping below
  # surfaces local progress when the local pull is running, and uses
  # :queued / :checking to communicate provider-side phases.

  defp apply_state(base, %ProviderJob{state: :queued}, _fs, _dl),
    do: %{base | state: :queued, progress: 0.0, downloaded: 0}

  # Provider is pulling from the swarm — surface it as `:downloading` with the
  # provider's progress so the operator sees forward motion, but in the
  # broader sense "Mydia hasn't received any bytes yet locally". We mirror
  # provider progress here because the UI's existing `:downloading` badge
  # is the most informative we have without a sub-state column.
  defp apply_state(base, %ProviderJob{state: :downloading} = job, _fs, _dl) do
    downloaded = mirror_downloaded(job)
    %{base | state: :downloading, downloaded: downloaded}
  end

  # Provider has finished from the swarm and is packaging/caching to its
  # hoster — surface as `:checking` so the UI shows distinct "verifying"
  # state instead of an in-progress percentage. Mydia still has nothing
  # locally; checking the package on the provider side fits the
  # `DownloadStatus :checking` taxonomy ("verifying/repairing/moving").
  defp apply_state(base, %ProviderJob{state: :finalizing}, _fs, _dl),
    do: %{base | state: :checking, progress: 0.0, downloaded: 0}

  # Provider is fully ready AND Mydia's local fetcher has finished writing
  # the file → save_path is set on the Download → terminal `:completed`.
  defp apply_state(base, %ProviderJob{state: :ready}, _fs, %Download{
         metadata: %{"save_path" => save_path}
       })
       when is_binary(save_path) and save_path != "" do
    %{
      base
      | state: :completed,
        progress: 100.0,
        downloaded: base.size,
        save_path: save_path,
        completed_at: DateTime.utc_now()
    }
  end

  # Provider is ready but the fetcher itself failed terminally.
  defp apply_state(base, %ProviderJob{state: :ready}, :failed, _dl),
    do: %{base | state: :error, progress: 0.0, downloaded: 0}

  # Provider is ready and the local fetcher is actively streaming. Surface
  # the fetcher's progress (bytes_pulled / size) — NOT the provider's
  # mirrored 100%. This is the case the operator should see most often
  # during a healthy debrid download.
  defp apply_state(base, %ProviderJob{state: :ready}, :running, %Download{} = download) do
    bytes = download.bytes_pulled || 0

    progress =
      if base.size > 0 do
        bytes / base.size * 100.0
      else
        0.0
      end

    %{base | state: :downloading, downloaded: bytes, progress: progress}
  end

  # Provider is ready, no fetcher running yet, no save_path. The Mydia-side
  # work hasn't started (or hasn't been claimed since the last cron tick).
  # Report `:queued` rather than mirroring the provider's 100% — the
  # operator hasn't received any bytes locally yet, even though RD says
  # the torrent is "done" on their side.
  defp apply_state(base, %ProviderJob{state: :ready}, _fetcher_state, _download),
    do: %{base | state: :queued, progress: 0.0, downloaded: 0}

  # A terminal provider failure. `failure_category` / `failure_detail` are
  # whatever the provider managed to classify; both may be nil, which the
  # monitor renders as the pre-#237 generic message.
  defp apply_state(base, %ProviderJob{state: :error} = job, _fs, _dl) do
    %{
      base
      | state: :error,
        progress: 0.0,
        downloaded: 0,
        failure_category: job.failure_category,
        failure_detail: job.failure_detail
    }
  end

  defp mirror_downloaded(%ProviderJob{total_bytes: total, progress: p})
       when is_integer(total) and total > 0 and is_number(p) do
    trunc(total * (min(max(p, 0.0), 100.0) / 100.0))
  end

  defp mirror_downloaded(_), do: 0

  defp clamped_progress(nil), do: 0.0
  defp clamped_progress(p) when is_number(p), do: min(max(p * 1.0, 0.0), 100.0)
end
