defmodule Mydia.Indexers.Cardigann.Wasm.HostHttp do
  @moduledoc """
  The `mydia:cardigann/host` imports. Each `http-request` is exactly one HTTP
  exchange with redirects off: Prowlarr's own HttpClient in the guest follows
  redirects and scopes cookies per domain, so the host never carries a Cookie
  header to a host the guest did not choose. Egress goes through the plugin
  SSRF gate, a definition's requestDelay is enforced here (the guest's rate
  limiter is a no-op), and a Cloudflare challenge is solved through
  FlareSolverr when the definition has it enabled.

  Two layers. `exchange/2` takes and returns plain Elixir maps and is what the
  tests drive; `imports/1` wraps it with the Wasmex value-shape conversion
  recorded in `native/cardigann_guest/SPIKE.md` ("Wasmex value shapes"):
  `option<list<u8>>` request bodies, `list<u8>` response bodies as integer
  lists, and the `http-error` variant as `{case, message}`.

  The parity harness (`Mydia.Indexers.Cardigann.Parity`) can ride in the ctx:
  `:replay` answers every exchange from a recorded capture instead of the
  network (no throttle, gate or FlareSolverr), and `:record` collects each
  live exchange as the guest saw it. `Wasm.Adapter` copies them from the
  parity seam when it builds the ctx; this module never reads the seam, since
  the guest runs in a separate process.

  Request and response bodies, and Cookie and Authorization values, are
  credentials and are never logged. Only method, host and status are.
  """

  require Logger

  alias Mydia.Indexers.Cardigann.FlareSolverrFlow
  alias Mydia.Indexers.Cardigann.Parity.{Recorder, Replay, RequestKey}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.FlareSolverr.ClearanceCache
  alias Mydia.Indexers.RateLimiter
  alias Mydia.Plugins.Error, as: GateError
  alias Mydia.Plugins.Net.Gate

  @namespace "mydia:cardigann/host@1.0.0"

  @max_response_bytes 32 * 1024 * 1024
  # Prowlarr's HttpClient gives a request 100 s (ManagedHttpDispatcher). Slow
  # trackers (archive.org takes 30 to 50 s) answer Prowlarr and must answer here.
  @default_timeout_ms 100_000

  @type ctx :: %{
          required(:definition_id) => String.t(),
          required(:request_delay_ms) => non_neg_integer(),
          required(:flaresolverr) => map() | nil,
          # labels the releases a search returns; defaults to definition_id
          optional(:indexer_name) => String.t(),
          # test-only: allow localhost Bypass (e.g. allow_private_except_link_local: true)
          optional(:gate_opts) => keyword(),
          # benchmark only: index 1 accumulates the exchanges' wall-clock microseconds
          optional(:network) => :atomics.atomics_ref(),
          # test-only: called with {:task, pid}, {:watcher, pid} and {:instance, pid} by the engine
          optional(:guest_probe) => (term() -> any()),
          # parity harness: a Parity.Replay answering in place of the network
          optional(:replay) => pid(),
          # parity harness: a Parity.Recorder collecting the live exchanges
          optional(:record) => pid(),
          # set to 1 when a request goes to one of these login URLs
          optional(:login_watch) => %{targets: [URI.t()], hit: :atomics.atomics_ref()}
        }

  @type header :: %{name: String.t(), value: String.t()}
  @type request :: %{
          method: String.t(),
          url: String.t(),
          headers: [header()],
          body: binary() | nil
        }
  @type response :: %{status: non_neg_integer(), headers: [header()], body: binary()}
  @type error_kind :: :timeout | :connect | :blocked | :other

  # ── Wasmex layer ──────────────────────────────────────────────────────────

  @doc "The Wasmex imports map for `mydia:cardigann/host@1.0.0`."
  @spec imports(ctx()) :: map()
  def imports(ctx) do
    %{
      @namespace => %{
        "http-request" => {:fn, fn req -> http_request(ctx, req) end},
        "log" => {:fn, fn level, message -> log(ctx, level, message) end}
      }
    }
  end

  defp http_request(ctx, req) do
    req
    |> decode_request()
    |> then(&exchange(ctx, &1))
    |> encode_result()
  rescue
    # A raise inside an import surfaces as a reasonless trap in the guest.
    e -> encode_result({:error, {:other, "host http failure: " <> Exception.message(e)}})
  end

  @doc false
  # Record keys arrive as atoms or strings depending on atom existence in the VM
  # (SPIKE.md), the body as `:none | {:some, list_or_binary}`.
  @spec decode_request(map()) :: request()
  def decode_request(req) do
    %{
      method: field(req, :method),
      url: field(req, :url),
      headers: req |> field(:headers) |> List.wrap() |> Enum.map(&decode_header/1),
      body: decode_body(field(req, :body))
    }
  end

  defp decode_header(h), do: %{name: field(h, :name), value: field(h, :value)}

  defp decode_body({:some, body}), do: IO.iodata_to_binary(body)
  defp decode_body(_none_or_nil), do: nil

  defp field(map, key) do
    case map do
      %{^key => value} -> value
      _ -> Map.get(map, Atom.to_string(key))
    end
  end

  @doc false
  # `list<u8>` must go back as a list of integers; a binary traps the guest.
  # The error shape `{:error, {case, message}}` is the SPIKE-documented variant
  # encoding (`{:connect, msg}`), exercised by the spike for `connect` only.
  @spec encode_result({:ok, response()} | {:error, {error_kind(), String.t()}}) ::
          {:ok, map()} | {:error, {error_kind(), String.t()}}
  def encode_result({:ok, %{status: status, headers: headers, body: body}}) do
    {:ok, %{status: status, headers: headers, body: :binary.bin_to_list(body)}}
  end

  def encode_result({:error, {kind, message}}) when is_atom(kind) and is_binary(message),
    do: {:error, {kind, message}}

  # Guest-supplied text is never trusted with credentials, so even `error`
  # level stays at debug.
  defp log(ctx, level, message) do
    Logger.debug("cardigann guest #{ctx.definition_id} [#{level}]: #{message}")
    :ok
  end

  # ── Plain layer ───────────────────────────────────────────────────────────

  @doc """
  The request deadline when `:cardigann_http_timeout_ms` is not configured.
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  Performs one gated HTTP exchange for the guest. When the ctx carries
  `:replay`, the exchange is answered from the recorded capture instead, with
  no throttle, gate or FlareSolverr.
  """
  @spec exchange(ctx(), request()) :: {:ok, response()} | {:error, {error_kind(), String.t()}}
  def exchange(%{replay: replay}, req) when is_pid(replay) do
    key = RequestKey.new(req.method, req.url, req.body)

    case Replay.fetch(replay, key) do
      {:ok, %Exchange{error: nil} = ex} ->
        headers = Enum.map(ex.headers, fn {name, value} -> %{name: name, value: value} end)
        {:ok, %{status: ex.status, headers: headers, body: ex.body || ""}}

      {:ok, %Exchange{error: kind}} ->
        {:error, {replay_error_kind(kind), "parity replay: recorded #{kind}"}}

      :miss ->
        {:ok, %{status: 404, headers: [], body: "parity replay miss"}}
    end
  end

  def exchange(ctx, req) do
    note_login(ctx, req)
    :ok = RateLimiter.throttle(ctx.definition_id, ctx.request_delay_ms)
    started = System.monotonic_time(:microsecond)

    try do
      result = do_exchange(ctx, req)
      maybe_record(ctx, req, result)
      log_outcome(req, result)
      result
    after
      record_network(ctx, System.monotonic_time(:microsecond) - started)
    end
  end

  # Captures use the Elixir engine's transport reasons; the guest only knows
  # the four host error kinds. A capture recorded through the native engine
  # stores Req's raw reasons (:closed, :econnrefused, :nxdomain), and replaying
  # it through wasm must fail the way a live wasm exchange would, which
  # map_error/1 reports as :connect for all three.
  defp replay_error_kind(kind) when kind in [:timeout, :connect, :blocked], do: kind
  defp replay_error_kind(kind) when kind in [:closed, :econnrefused, :nxdomain], do: :connect
  defp replay_error_kind(_kind), do: :other

  # Prowlarr's search swallows a failed login into an empty page. The adapter
  # asks to be told when a call reached the login form (`:login_watch`), so it
  # can tell "the session expired and the captcha stopped the login" from "no
  # results".
  defp note_login(%{login_watch: %{targets: targets, hit: hit}}, req) do
    uri = URI.parse(req.url)

    if Enum.any?(targets, &same_endpoint?(&1, uri)), do: :atomics.put(hit, 1, 1)
    :ok
  end

  defp note_login(_ctx, _req), do: :ok

  # Scheme, host, port and path; the query is ignored (`login.php?returnto=`).
  defp same_endpoint?(%URI{} = target, %URI{} = uri) do
    target.scheme == uri.scheme and target.host == uri.host and target.port == uri.port and
      (target.path || "/") == (uri.path || "/")
  end

  defp maybe_record(%{record: recorder}, req, result) when is_pid(recorder),
    do: Recorder.record(recorder, RequestKey.new(req.method, req.url, req.body), result)

  defp maybe_record(_ctx, _req, _result), do: :ok

  defp do_exchange(ctx, req) do
    with {:ok, response} <- send_once(ctx, req) do
      maybe_solve(ctx, req, response)
    end
  end

  defp send_once(ctx, req) do
    req = apply_clearance(ctx, req)
    host = URI.parse(req.url).host

    opts =
      [
        allowed_hosts: if(host, do: [host], else: []),
        slug: "cardigann",
        # High volume, and query strings carry tracker apikeys and passkeys.
        audit: false,
        method: req.method,
        headers: header_map(req.headers),
        timeout: Application.get_env(:mydia, :cardigann_http_timeout_ms, @default_timeout_ms),
        max_bytes: @max_response_bytes
      ]
      |> put_body(req.body)
      |> Keyword.merge(Map.get(ctx, :gate_opts, []))

    case Gate.request(req.url, opts) do
      {:ok, %{status: status, headers: headers, body: body}} ->
        {headers, body} = headers |> normalize_headers() |> decompress(body)
        {:ok, %{status: status, headers: headers, body: body}}

      {:error, %GateError{} = error} ->
        {:error, map_error(error)}
    end
  end

  defp put_body(opts, nil), do: opts
  defp put_body(opts, body), do: Keyword.put(opts, :body, body)

  # The gate sets Host itself from the validated URL; a guest-chosen Host would
  # only fight it. Duplicate request header names fold into one value.
  defp header_map(headers) do
    headers
    |> Enum.reject(&(String.downcase(&1.name) == "host"))
    |> Enum.reduce(%{}, fn %{name: name, value: value}, acc ->
      key = String.downcase(name)

      Map.update(acc, key, {name, value}, fn {first_name, existing} ->
        {first_name, existing <> separator(key) <> value}
      end)
    end)
    |> Map.new(fn {_key, {name, value}} -> {name, value} end)
  end

  defp separator(name), do: if(String.downcase(name) == "cookie", do: "; ", else: ", ")

  # One entry per value, lower-cased names, so multiple set-cookie stay separate.
  defp normalize_headers(headers) do
    for {name, values} <- headers, value <- List.wrap(values) do
      %{name: String.downcase(to_string(name)), value: to_string(value)}
    end
  end

  # The gate hands the body back as it came off the wire. Prowlarr's HTTP client
  # decompresses gzip itself (and drops Content-Encoding and Content-Length), and
  # some trackers compress even when the request sent no Accept-Encoding, so a
  # gzip body is inflated here. Any other encoding, or a body that does not
  # inflate within the response cap, is passed through untouched.
  defp decompress(headers, body) do
    encodings =
      for %{name: "content-encoding", value: v} <- headers, do: String.downcase(String.trim(v))

    with [encoding] <- encodings,
         true <- encoding in ["gzip", "x-gzip"],
         {:ok, inflated} <- gunzip(body) do
      {Enum.reject(headers, &(&1.name in ["content-encoding", "content-length"])), inflated}
    else
      _ -> {headers, body}
    end
  end

  defp gunzip(body) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, body), [], 0)
    catch
      _, _ -> :error
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {state, chunk}, acc, size) do
    size = size + IO.iodata_length(chunk)
    acc = [acc | chunk]

    cond do
      size > @max_response_bytes -> :error
      state == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate(z, :zlib.safeInflate(z, []), acc, size)
    end
  end

  @connect_reasons ~w(econnrefused nxdomain closed ehostunreach enetunreach econnreset econnaborted)

  defp map_error(%GateError{type: :timeout, message: m}), do: {:timeout, m}
  defp map_error(%GateError{type: :blocked, message: m}), do: {:blocked, m}
  defp map_error(%GateError{type: :capability_denied, message: m}), do: {:blocked, m}
  # A malformed, non-http(s), userinfo or numeric-host URL is a policy refusal.
  defp map_error(%GateError{type: :invalid_url, message: m}), do: {:blocked, m}

  defp map_error(%GateError{type: :network_error, message: m}) do
    if String.contains?(m, @connect_reasons) or String.contains?(m, "could not resolve"),
      do: {:connect, m},
      else: {:other, m}
  end

  defp map_error(%GateError{message: m}), do: {:other, m}

  # ── FlareSolverr ──────────────────────────────────────────────────────────

  # A clearance cached for the host rides every request the definition makes to
  # it: its user-agent replaces the guest's (the clearance is bound to it) and
  # its cookies join the guest's Cookie header.
  defp apply_clearance(%{flaresolverr: %{enabled: true}}, req) do
    case ClearanceCache.lookup(req.url) do
      {:ok, clearance} ->
        pairs = Enum.map(clearance.cookies, fn {n, v} -> "#{n}=#{v}" end)

        %{
          req
          | headers: req.headers |> put_user_agent(clearance.user_agent) |> add_cookies(pairs)
        }

      :none ->
        req
    end
  end

  defp apply_clearance(_ctx, req), do: req

  defp put_user_agent(headers, nil), do: headers

  defp put_user_agent(headers, ua) do
    Enum.reject(headers, &(String.downcase(&1.name) == "user-agent")) ++
      [%{name: "User-Agent", value: ua}]
  end

  defp add_cookies(headers, []), do: headers

  defp add_cookies(headers, pairs) do
    {cookies, others} = Enum.split_with(headers, &(String.downcase(&1.name) == "cookie"))
    joined = Enum.map_join(cookies, "; ", & &1.value)
    value = Enum.join(Enum.reject([joined | pairs], &(&1 == "")), "; ")
    others ++ [%{name: "Cookie", value: value}]
  end

  defp maybe_solve(%{flaresolverr: fs} = ctx, req, response) when is_map(fs) and fs != %{} do
    with true <- fs[:enabled] == true,
         {:ok, params} <- solve_params(req),
         true <- CardigannSearchEngine.cloudflare_challenge?(response) do
      solve_and_repeat(ctx, req, params)
    else
      _ -> {:ok, response}
    end
  end

  defp maybe_solve(_ctx, _req, response), do: {:ok, response}

  # FlareSolverr can only drive GET and POST.
  defp solve_params(%{method: method, body: body}) do
    case String.upcase(method) do
      "GET" -> {:ok, %{method: :get, query_params: %{}}}
      "POST" -> {:ok, %{method: :post, query_params: body || ""}}
      _ -> :error
    end
  end

  defp solve_and_repeat(ctx, req, params) do
    Logger.info("Cardigann: #{ctx.definition_id} met a Cloudflare challenge, using FlareSolverr")
    # A challenge despite a cached clearance means that clearance is stale.
    ClearanceCache.delete(req.url)

    with {:ok, solved} <- earn_clearance(ctx, req, params),
         {:ok, repeated} <- send_once(ctx, req) do
      if CardigannSearchEngine.cloudflare_challenge?(repeated) do
        # The clearance did not carry over to a plain HTTP client: fall back to
        # the page Chrome rendered, and stop caching the useless clearance.
        ClearanceCache.delete(req.url)
        {:ok, rendered(solved)}
      else
        {:ok, repeated}
      end
    end
  end

  defp earn_clearance(ctx, req, params) do
    case FlareSolverrFlow.earn_clearance(ctx.definition_id, req.url, params) do
      {:ok, _} = ok -> ok
      {:error, %{message: message}} -> {:error, {:other, message}}
    end
  end

  defp rendered(solved) do
    rendered = FlareSolverrFlow.rendered_response(solved)

    %{
      status: rendered.status,
      body: rendered.body,
      headers:
        for {name, value} <- rendered.headers do
          %{name: String.downcase(to_string(name)), value: to_string(value)}
        end
    }
  end

  # ── Bookkeeping ───────────────────────────────────────────────────────────

  defp record_network(%{network: network}, micros), do: :atomics.add(network, 1, micros)
  defp record_network(_ctx, _micros), do: :ok

  defp log_outcome(req, {:ok, %{status: status}}),
    do: Logger.debug("Cardigann http #{req.method} #{URI.parse(req.url).host} -> #{status}")

  defp log_outcome(req, {:error, {kind, _}}),
    do: Logger.debug("Cardigann http #{req.method} #{URI.parse(req.url).host} failed: #{kind}")
end
