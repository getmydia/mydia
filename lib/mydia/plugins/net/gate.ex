defmodule Mydia.Plugins.Net.Gate do
  @moduledoc """
  SSRF-resistant outbound HTTP gate — the plugin platform's security boundary
  (KTD5, R6).

  A WASM guest has no ambient sockets (WASM core + WASI Preview 1 expose no
  socket-creation API), so this gate is a plugin's *only* network egress, reached
  through the `http_request` host function (`Mydia.Plugins.HostFunctions`). Every
  call passes the full validation chain before any connection is made:

    1. **Parse & normalize.** Only `http`/`https`; URLs with embedded userinfo
       (`user:pass@host`) or ambiguous numeric hosts (decimal/octal/hex integer
       literals) are rejected outright.
    2. **Exact-hostname allowlist.** The host must match one of the plugin's
       granted `net:http` hostnames exactly (case-insensitive). No wildcards —
       a wildcard is a DNS-subdomain exfiltration channel.
    3. **Resolve & validate every IP.** The gate resolves A + AAAA itself and
       rejects the call if *any* resolved address is loopback / RFC1918 /
       link-local (incl. `169.254.169.254`) / CGNAT / ULA / multicast / reserved.
       IPv4-mapped and NAT64 IPv6 addresses are unwrapped and the embedded IPv4
       is validated, so `::ffff:169.254.169.254` cannot slip through.
    4. **Pin the connection to the validated IP.** The request connects to the
       validated IP literal; the original hostname is passed only via
       `connect_options: [hostname: host]` for TLS SNI / certificate
       verification. The adapter never re-resolves, so the validate→connect
       DNS-rebinding (TOCTOU) window is closed.
    5. **No redirect following, capped response, aggressive timeouts.** A 3xx is
       returned verbatim (never followed), so a `Location` pointing at a private
       IP cannot escape the gate. Responses past `max_bytes` are rejected.

  Every call emits a `plugin` audit event (slug, URL, status, byte size) so
  egress is queryable and surfaceable in the admin UI (U9).

  ## Test seam

  `:allow_private` (default `false`) skips the private-range check. It is set
  **only** by tests so a happy-path round trip can run against a loopback Bypass
  server; production wiring never sets it, and a guest can never reach it (it is
  a host-side Elixir option, not part of the guest request).
  """

  import Bitwise

  require Logger

  alias Mydia.Events
  alias Mydia.Plugins.Error

  @default_timeout_ms 5_000
  @default_max_bytes 1_048_576

  @type result :: %{status: non_neg_integer(), headers: map(), body: binary()}

  @doc """
  Performs a gated request to `url`.

  Required option:

    * `:allowed_hosts` — the plugin's granted exact `net:http` hostnames.

  Optional:

    * `:slug` — plugin slug, for the audit event
    * `:method` — `"GET"` (default), `"POST"`, …
    * `:headers` — request headers as a map
    * `:body` — request body (binary)
    * `:max_bytes` — response cap (default 1 MiB)
    * `:timeout` — connect/receive timeout in ms (default 5000)
    * `:resolver` — `(host -> {:ok, [ip_tuple]} | {:error, term})`, injected in tests
    * `:allow_private` — test seam (see moduledoc)
    * `:endpoint_trust` — `:manifest` (default) or `:operator`. `:operator`
      skips the allowlist and private-range checks for a destination the
      operator configured on an instance-scoped connection, where the guest
      supplies only a path. Every other check still applies. This is NOT
      `:allow_private`, which remains a test-only seam.
  """
  @spec request(String.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def request(url, opts) when is_binary(url) do
    allowed = Keyword.get(opts, :allowed_hosts, [])
    operator? = Keyword.get(opts, :endpoint_trust, :manifest) == :operator
    started = System.monotonic_time()

    outcome =
      with {:ok, uri} <- parse_url(url),
           :ok <- check_allowlist(uri.host, allowed, operator?),
           {:ok, ip} <- resolve_and_validate(uri.host, opts) do
        perform(uri, ip, opts)
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)

    audit(url, outcome, duration_ms, opts)
    outcome
  end

  # ── 1. Parse & normalize ──────────────────────────────────────────────────

  defp parse_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, Error.new(:invalid_url, "scheme must be http or https")}

      is_nil(uri.host) or uri.host == "" ->
        {:error, Error.new(:invalid_url, "missing host")}

      uri.userinfo != nil ->
        {:error, Error.new(:invalid_url, "userinfo in URL is not allowed")}

      numeric_host?(uri.host) ->
        {:error, Error.new(:invalid_url, "ambiguous numeric host: #{uri.host}")}

      true ->
        {:ok, uri}
    end
  end

  # Reject integer-encoded hosts (decimal `2130706433`, hex `0x7f000001`) that
  # resolvers/curl would treat as IPs but `:inet` will not — they are a private-
  # IP smuggling vector. Genuine dotted IPv4/bracketed IPv6 literals pass.
  defp numeric_host?(host) do
    cond do
      String.starts_with?(host, "0x") or String.starts_with?(host, "0X") -> true
      Regex.match?(~r/^\d+$/, host) -> true
      true -> false
    end
  end

  # ── 2. Exact-hostname allowlist ───────────────────────────────────────────

  # An operator-configured endpoint is not in any manifest grant and never could
  # be: the operator typed the address after the manifest was written.
  defp check_allowlist(_host, _allowed, true), do: :ok

  defp check_allowlist(host, allowed, false), do: check_allowlist(host, allowed)

  defp check_allowlist(host, allowed) do
    host_down = String.downcase(host)
    allowed_down = Enum.map(allowed, &String.downcase/1)

    if host_down in allowed_down do
      :ok
    else
      {:error,
       Error.new(:capability_denied, "host #{host} is not on the plugin's net:http allowlist")}
    end
  end

  # ── 3. Resolve & validate ─────────────────────────────────────────────────

  defp resolve_and_validate(host, opts) do
    resolver = Keyword.get(opts, :resolver, &default_resolve/1)

    allow_private =
      Keyword.get(opts, :allow_private, false) or
        Keyword.get(opts, :endpoint_trust, :manifest) == :operator

    case resolver.(host) do
      {:ok, []} ->
        {:error, Error.new(:network_error, "no addresses for #{host}")}

      {:ok, ips} ->
        validate_ips(ips, allow_private)

      {:error, reason} ->
        {:error, Error.new(:network_error, "could not resolve #{host}: #{inspect(reason)}")}
    end
  end

  # All resolved addresses must be public (deny-if-any-private) so a multi-record
  # name can't smuggle one private answer past the gate. Returns one validated IP
  # to pin the connection to.
  defp validate_ips(ips, allow_private) do
    cond do
      allow_private ->
        {:ok, hd(ips)}

      blocked = Enum.find(ips, &(not public_ip?(&1))) ->
        {:error,
         Error.new(:blocked, "destination resolves to a private/blocked IP: #{fmt_ip(blocked)}")}

      true ->
        {:ok, hd(ips)}
    end
  end

  defp default_resolve(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _} ->
        v4 = getaddrs(charlist, :inet)
        v6 = getaddrs(charlist, :inet6)

        case v4 ++ v6 do
          [] -> {:error, :nxdomain}
          ips -> {:ok, ips}
        end
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, ips} -> ips
      {:error, _} -> []
    end
  end

  # ── IP classification ─────────────────────────────────────────────────────

  @doc false
  @spec public_ip?(:inet.ip_address()) :: boolean()
  def public_ip?({a, b, _c, _d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 168 -> false
      a == 192 and b == 0 -> false
      a == 100 and b in 64..127 -> false
      a == 198 and b in 18..19 -> false
      a >= 224 -> false
      true -> true
    end
  end

  def public_ip?({0, 0, 0, 0, 0, 0xFFFF, g7, g8}) do
    # IPv4-mapped IPv6 (::ffff:a.b.c.d) — validate the embedded IPv4.
    public_ip?(embedded_v4(g7, g8))
  end

  def public_ip?({0x0064, 0xFF9B, 0, 0, 0, 0, g7, g8}) do
    # NAT64 (64:ff9b::/96) — validate the embedded IPv4.
    public_ip?(embedded_v4(g7, g8))
  end

  def public_ip?({h1, h2, h3, h4, h5, h6, h7, h8}) do
    cond do
      {h1, h2, h3, h4, h5, h6, h7, h8} == {0, 0, 0, 0, 0, 0, 0, 0} -> false
      {h1, h2, h3, h4, h5, h6, h7, h8} == {0, 0, 0, 0, 0, 0, 0, 1} -> false
      (h1 &&& 0xFE00) == 0xFC00 -> false
      (h1 &&& 0xFFC0) == 0xFE80 -> false
      (h1 &&& 0xFF00) == 0xFF00 -> false
      h1 == 0x2001 and h2 == 0x0DB8 -> false
      true -> true
    end
  end

  defp embedded_v4(g7, g8), do: {g7 >>> 8, g7 &&& 0xFF, g8 >>> 8, g8 &&& 0xFF}

  defp fmt_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  # ── 4 & 5. Pin connection, no redirects, size cap ─────────────────────────

  defp perform(uri, ip, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    headers = Keyword.get(opts, :headers, %{})
    body = Keyword.get(opts, :body)

    with {:ok, method} <- normalize_method(Keyword.get(opts, :method, "GET")) do
      pinned_url = pin_url(uri, ip)

      req_opts =
        [
          method: method,
          url: pinned_url,
          headers: Map.put(headers, "host", uri.authority || uri.host),
          connect_options: [hostname: uri.host, timeout: timeout],
          # The authoritative deadline is the outer task timeout below; an
          # `:infinity` receive avoids Finch's streaming-timeout path, which exits
          # the streaming process with `:shutdown` instead of returning cleanly.
          receive_timeout: :infinity,
          redirect: false,
          retry: false,
          decode_body: false,
          into: size_capped_collector(max_bytes)
        ]
        |> maybe_put_body(body)

      # Run the request in an isolated, monitored task. In production the gate is
      # called from the Wasmex instance process running the guest's host-function
      # callback; Finch's streaming links a worker to the caller, so a transport
      # abort would otherwise propagate `:shutdown` and kill the guest. async_nolink
      # turns that into a deliverable message, and the outer deadline is the single
      # authoritative timeout.
      task = Task.Supervisor.async_nolink(Mydia.TaskSupervisor, fn -> do_request(req_opts) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, Error.new(:timeout, "request timed out after #{timeout}ms")}
        {:exit, reason} -> {:error, classify_exit(reason)}
      end
    end
  end

  defp do_request(req_opts) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{body: {:too_large, cap}}} ->
        {:error, Error.new(:too_large, "response exceeded #{cap} bytes")}

      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status: status, headers: resp_headers, body: ensure_binary(resp_body)}}

      {:error, %{__struct__: s} = err}
      when s in [Req.TransportError, Req.HTTPError, Mint.TransportError, Mint.HTTPError] ->
        {:error, classify_transport_error(err)}

      {:error, reason} ->
        {:error, Error.new(:network_error, "request failed: #{inspect(reason)}")}
    end
  end

  defp classify_exit(reason) do
    if reason |> inspect() |> String.contains?("timeout") do
      Error.new(:timeout, "connection or receive timed out")
    else
      Error.new(:network_error, "request process exited: #{inspect(reason)}")
    end
  end

  # Connect to the validated IP literal; SNI/cert/Host come from the original
  # hostname via connect_options, so no re-resolution happens.
  defp pin_url(uri, ip) do
    host_literal =
      case tuple_size(ip) do
        4 -> fmt_ip(ip)
        8 -> "[#{fmt_ip(ip)}]"
      end

    %{uri | host: host_literal, authority: nil, userinfo: nil} |> URI.to_string()
  end

  # Stream the body, halting (and flagging) once it passes the cap, so a hostile
  # or runaway server can't force unbounded buffering. Chunks accumulate as
  # iodata (a reversed list) plus a running byte count, so the cap is enforced
  # without the O(n²) binary copying that `acc <> data` would incur on large
  # responses (e.g. tens-of-MiB package downloads). The iodata is flattened to a
  # single binary once, in `do_request/1`.
  defp size_capped_collector(max_bytes) do
    fn {:data, data}, {req, resp} ->
      {iodata, size} = collector_acc(resp.body)
      new_size = size + byte_size(data)

      if new_size > max_bytes do
        {:halt, {req, %{resp | body: {:too_large, max_bytes}}}}
      else
        {:cont, {req, %{resp | body: {:iodata, [data | iodata], new_size}}}}
      end
    end
  end

  # Req seeds the body as an empty binary before the first chunk; after that the
  # collector carries its own `{:iodata, list, size}` accumulator.
  defp collector_acc({:iodata, iodata, size}), do: {iodata, size}
  defp collector_acc(_), do: {[], 0}

  defp ensure_binary(body) when is_binary(body), do: body

  defp ensure_binary({:iodata, iodata, _size}),
    do: iodata |> Enum.reverse() |> IO.iodata_to_binary()

  defp ensure_binary(_), do: ""

  defp maybe_put_body(req_opts, nil), do: req_opts
  defp maybe_put_body(req_opts, body), do: Keyword.put(req_opts, :body, body)

  # Map an HTTP method (string, case-insensitive, or atom) to the lowercase atom
  # Req/Finch expects. An explicit allowlist avoids `String.to_existing_atom/1`
  # silently coercing valid-but-unknown methods (PATCH/OPTIONS, depending on
  # which atoms happen to be loaded) into `:get` and issuing the wrong request.
  # Anything off the allowlist is rejected so the bad input surfaces to the
  # guest instead of being executed as a different verb.
  @http_methods %{
    "get" => :get,
    "head" => :head,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "options" => :options,
    "trace" => :trace,
    "connect" => :connect
  }

  defp normalize_method(method) when is_atom(method) do
    normalize_method(Atom.to_string(method))
  end

  defp normalize_method(method) when is_binary(method) do
    downcased = String.downcase(method)

    case Map.fetch(@http_methods, downcased) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, Error.new(:invalid_request, "unsupported HTTP method: #{method}")}
    end
  end

  defp normalize_method(other),
    do: {:error, Error.new(:invalid_request, "invalid HTTP method: #{inspect(other)}")}

  defp classify_transport_error(%{reason: :timeout}),
    do: Error.new(:timeout, "connection or receive timed out")

  defp classify_transport_error(err),
    do: Error.new(:network_error, "transport error: #{inspect(err)}")

  # ── Audit ─────────────────────────────────────────────────────────────────

  # Auditing must never break egress: a failure to record the event (e.g. no DB
  # connection in the caller's context) is logged and swallowed.
  defp audit(url, outcome, duration_ms, opts) do
    slug = Keyword.get(opts, :slug, "unknown")
    method = opts |> Keyword.get(:method, "GET") |> to_string() |> String.upcase()
    {status, severity, bytes} = audit_fields(outcome)

    Events.create_event_async(%{
      category: "plugin",
      type: "plugin.http_request",
      actor_type: :system,
      actor_id: slug,
      severity: severity,
      metadata: %{
        "slug" => slug,
        "method" => method,
        "url" => url,
        "host" => URI.parse(url).host,
        "status" => status,
        "bytes" => bytes,
        "duration_ms" => duration_ms,
        "outcome" => outcome_label(outcome)
      }
    })
  rescue
    e -> Logger.warning("plugin egress audit failed: #{Exception.message(e)}")
  end

  defp audit_fields({:ok, %{status: status, body: body}}),
    do: {status, :info, byte_size(body)}

  defp audit_fields({:error, _}), do: {nil, :warning, 0}

  defp outcome_label({:ok, _}), do: "ok"
  defp outcome_label({:error, %Error{type: type}}), do: to_string(type)
end
