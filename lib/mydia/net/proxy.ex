defmodule Mydia.Net.Proxy do
  @moduledoc """
  Outbound HTTP proxy configuration, routing and error descriptions.

  `effective/2` resolves the layered `proxy` config section plus the standard
  `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` variables into a `%Mydia.Net.Proxy{}`.
  `route/2` decides per host whether a request goes direct or through the proxy.
  Routing never performs DNS lookups. Credentials in the proxy URL become a
  `proxy-authorization` header and are masked in `display_url`; they never
  appear in error messages.
  """

  require Logger

  alias Mydia.Config.Schema.Proxy, as: ProxyConfig
  alias Mydia.Net.Proxy.Bypass
  alias Mydia.Plugins.Net.Gate

  @enforce_keys [:proxy, :endpoint, :display_url, :url_from]
  defstruct proxy: nil,
            headers: [],
            bypass: [],
            display_url: nil,
            endpoint: nil,
            url_from: :config,
            bypass_from: :none

  @type headers :: [{String.t(), String.t()}]
  @type t :: %__MODULE__{
          proxy: {:http | :https, String.t(), :inet.port_number(), []},
          headers: headers(),
          bypass: [Bypass.entry()],
          display_url: String.t(),
          endpoint: String.t(),
          url_from: :config | :standard_env,
          bypass_from: :config | :standard_env | :none
        }

  @url_vars ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
  @bypass_vars ["NO_PROXY", "no_proxy"]
  @config_key {__MODULE__, :config}
  @error_key {__MODULE__, :config_error}
  @test_timeout 5_000

  # -- effective config ------------------------------------------------------

  @doc """
  Resolves the effective proxy from the layered config and standard env vars.

  Returns `{:ok, nil}` when no proxy is configured.
  """
  @spec effective(ProxyConfig.t() | nil, (String.t() -> String.t() | nil)) ::
          {:ok, t() | nil} | {:error, String.t()}
  def effective(proxy_config, getenv) when is_function(getenv, 1) do
    case resolve(proxy_config, getenv) do
      {:error, label, reason} -> {:error, error_message(label, reason)}
      ok -> ok
    end
  end

  # effective/2 with the failure kept apart: the variable (or "proxy.url")
  # and the reason, so refresh/2 can report both.
  defp resolve(proxy_config, getenv) do
    {config_url, config_bypass} = layered(proxy_config)

    case pick_url(config_url, getenv) do
      nil ->
        {:ok, nil}

      {url, source, label} ->
        with {:ok, struct} <- build(url, source, label) do
          {bypass_string, bypass_from} = pick_bypass(config_bypass, getenv)
          {:ok, %{struct | bypass: Bypass.parse(bypass_string), bypass_from: bypass_from}}
        end
    end
  end

  defp layered(%ProxyConfig{url: url, bypass: bypass}), do: {present(url), present(bypass)}
  defp layered(nil), do: {nil, nil}

  defp pick_url(nil, getenv) do
    Enum.find_value(@url_vars, fn var ->
      if value = present(getenv.(var)), do: {value, :standard_env, var}
    end)
  end

  defp pick_url(url, _getenv), do: {url, :config, "proxy.url"}

  defp pick_bypass(nil, getenv) do
    Enum.find_value(@bypass_vars, {nil, :none}, fn var ->
      if value = present(getenv.(var)), do: {value, :standard_env}
    end)
  end

  defp pick_bypass(bypass, _getenv), do: {bypass, :config}

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp present(_), do: nil

  defp build(url, source, label) do
    case parse_url(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port} = uri} ->
        {:ok,
         %__MODULE__{
           proxy: {String.to_existing_atom(scheme), host, port, []},
           headers: auth_headers(uri.userinfo),
           display_url: display_url(scheme, host, port, uri.userinfo),
           endpoint: "#{host}:#{port}",
           url_from: source
         }}

      {:error, reason} ->
        {:error, label, reason}
    end
  end

  @typedoc "Why `parse_url/1` refused a URL. Never carries the URL itself."
  @type parse_error :: :invalid | :invalid_port | {:unsupported_scheme, String.t()}

  @doc """
  Parses and validates a proxy URL. The one parser behind both the config
  schema's validation and routing, so the two never disagree.

  Returns the parsed `URI` with a scheme of `http` or `https`, a non-empty host
  and an integer port. The port is checked on the raw authority, because
  `URI.parse/1` turns an out-of-range port into nil, a non-numeric one into the
  scheme's default, and a `#` in a password into a fragment (moving the host).
  """
  @spec parse_url(String.t()) :: {:ok, URI.t()} | {:error, parse_error()}
  def parse_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if valid_port?(uri), do: {:ok, uri}, else: {:error, :invalid_port}

      %URI{scheme: scheme}
      when is_binary(scheme) and scheme not in ["http", "https"] ->
        # Without "://" the "scheme" is really a host or a user name.
        if String.contains?(url, "://"),
          do: {:error, {:unsupported_scheme, scheme}},
          else: {:error, :invalid}

      _ ->
        {:error, :invalid}
    end
  end

  defp valid_port?(%URI{authority: authority, port: port}) when is_integer(port) do
    case raw_port(authority) do
      :none -> true
      digits -> digits =~ ~r/\A[0-9]{1,5}\z/ and String.to_integer(digits) in 1..65_535
    end
  end

  defp valid_port?(_uri), do: false

  # The port substring of the authority, or :none when it names no port.
  defp raw_port(authority) do
    host_port = authority |> String.split("@") |> List.last()

    case host_port do
      "[" <> rest ->
        case String.split(rest, "]", parts: 2) do
          [_ip, ":" <> port] -> port
          _ -> :none
        end

      _ ->
        case String.split(host_port, ":", parts: 2) do
          [_host, port] -> port
          [_host] -> :none
        end
    end
  end

  defp error_reason(:invalid), do: "expected http://host:port or https://host:port"
  defp error_reason(:invalid_port), do: "the port must be a number from 1 to 65535"
  defp error_reason({:unsupported_scheme, scheme}), do: "#{scheme} is not supported"

  defp error_message(label, {:unsupported_scheme, _} = reason),
    do: "unsupported proxy URL in #{label}: #{error_reason(reason)}"

  defp error_message(label, reason),
    do: "invalid proxy URL in #{label}: #{error_reason(reason)}"

  defp auth_headers(nil), do: []

  defp auth_headers(userinfo) do
    {user, pass} = split_userinfo(userinfo)
    credentials = URI.decode(user) <> ":" <> URI.decode(pass)
    [{"proxy-authorization", "Basic " <> Base.encode64(credentials)}]
  end

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, ""}
    end
  end

  defp display_url(scheme, host, port, userinfo) do
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host

    credentials =
      case userinfo do
        nil -> ""
        info -> masked_userinfo(split_userinfo(info))
      end

    "#{scheme}://#{credentials}#{host}:#{port}"
  end

  # A user with no password shows bare, so the mask never stands for a
  # password that does not exist.
  defp masked_userinfo({user, ""}), do: user <> "@"
  defp masked_userinfo({user, _password}), do: user <> ":****@"

  # -- cached config ---------------------------------------------------------

  @doc """
  Stores the effective config (or nil) for request-time routing, and clears
  any error a previous `refresh/2` recorded.
  """
  @spec put_config(t() | nil) :: :ok
  def put_config(config) do
    :persistent_term.put(@config_key, config)
    put_error(nil)
  end

  @doc "The cached effective config, or nil when unset."
  @spec current() :: t() | nil
  def current, do: :persistent_term.get(@config_key, nil)

  @doc """
  Why the last `refresh/2` ignored a proxy setting, as `{source, reason}`
  (`{"HTTPS_PROXY", "socks5 is not supported"}`), or nil. The reason never
  contains the URL, so it carries no credentials.
  """
  @spec config_error() :: {String.t(), String.t()} | nil
  def config_error, do: :persistent_term.get(@error_key, nil)

  defp put_error(error) do
    # persistent_term writes are expensive (a global GC pass), so skip a
    # write that changes nothing.
    if :persistent_term.get(@error_key, nil) != error,
      do: :persistent_term.put(@error_key, error)

    :ok
  end

  @doc """
  The environment lookup proxy configuration reads, `System.get_env/1` unless
  the `:proxy_getenv` application env names another 1-arity function. The test
  environment sets one that hides the developer's proxy variables.
  """
  @spec getenv() :: (String.t() -> String.t() | nil)
  def getenv, do: Application.get_env(:mydia, :proxy_getenv, &System.get_env/1)

  @doc """
  Recomputes the effective proxy from a runtime config and caches it.

  Called wherever the runtime config is cached (application boot and
  `Mydia.Config.Loader.reload/1`). The layered `proxy.url` is validated by the
  config schema, so an unusable URL here comes from `HTTPS_PROXY` /
  `HTTP_PROXY`: it logs a warning, caches `nil` so requests go direct, and is
  kept for `config_error/0`, which the Settings page shows.
  """
  @spec refresh(Mydia.Config.Schema.t(), (String.t() -> String.t() | nil)) :: :ok
  def refresh(%Mydia.Config.Schema{} = config, getenv \\ getenv()) do
    case resolve(config.proxy, getenv) do
      {:ok, proxy} ->
        put_config(proxy)

      {:error, label, reason} ->
        Logger.warning("Ignoring outbound proxy: #{error_message(label, reason)}")
        put_config(nil)
        put_error({label, error_reason(reason)})
    end
  end

  # -- routing ---------------------------------------------------------------

  @doc """
  Decides how a request to `host` is sent.

  Returns `:direct` or `{:proxy, [proxy: tuple, proxy_headers: headers]}`
  (`proxy_headers` omitted when empty).
  """
  @spec route(String.t() | nil, t() | nil) :: :direct | {:proxy, keyword()}
  def route(_host, nil), do: :direct
  def route(nil, %__MODULE__{}), do: :direct

  def route(host, %__MODULE__{} = config) when is_binary(host) do
    host = Bypass.normalize_host(host)

    if direct?(host, config) do
      :direct
    else
      opts = [proxy: config.proxy]
      opts = if config.headers == [], do: opts, else: opts ++ [proxy_headers: config.headers]
      {:proxy, opts}
    end
  end

  defp direct?("", _config), do: true
  defp direct?("localhost", _config), do: true

  defp direct?(host, config) do
    case Bypass.host_ip(host) do
      nil -> not String.contains?(host, ".") or Bypass.match?(host, config.bypass)
      ip -> not Gate.public_ip?(ip) or Bypass.match?(host, config.bypass)
    end
  end

  # -- connection test -------------------------------------------------------

  @doc """
  Sends one GET to `url` through the configured proxy, for the Settings page's
  Test proxy button.

  The proxy is forced: bypass rules and automatic direct routing are skipped,
  so the test always exercises the proxy hop. Returns the status and latency,
  or an error message that names the proxy endpoint but never its
  credentials.
  """
  @spec test_connection(String.t()) ::
          {:ok, %{status: integer(), ms: non_neg_integer()}} | {:error, String.t()}
  def test_connection(url) when is_binary(url) do
    case current() do
      nil -> {:error, "No proxy is configured"}
      config -> forced_get(url, config)
    end
  end

  defp forced_get(url, config) do
    # Bound every hop so a proxy that accepts and never answers cannot hang the
    # Settings page's test. `timeout` covers the target connection; the proxy
    # hop takes its own options from the tuple: the TCP connect to the proxy
    # and Mint's CONNECT handshake (`tunnel_timeout`, 30s by default).
    {scheme, host, port, _opts} = config.proxy

    proxy =
      {scheme, host, port,
       [transport_opts: [timeout: @test_timeout], tunnel_timeout: @test_timeout]}

    connect = [proxy: proxy, timeout: @test_timeout]

    connect =
      if config.headers == [], do: connect, else: connect ++ [proxy_headers: config.headers]

    started = System.monotonic_time(:millisecond)

    case Req.get(url, connect_options: connect, retry: false, receive_timeout: 10_000) do
      # A plain-http request through a proxy gets the proxy's own answer as an
      # ordinary response rather than a tunnel error.
      {:ok, %Req.Response{status: 407}} ->
        {:error, "proxy #{config.endpoint} requires authentication"}

      {:ok, %Req.Response{status: status}} ->
        {:ok, %{status: status, ms: System.monotonic_time(:millisecond) - started}}

      {:error, exception} ->
        {:error, describe(exception, config.endpoint) || Exception.message(exception)}
    end
  end

  # -- error descriptions ----------------------------------------------------

  @doc """
  Describes a request failure in terms of the proxy, or nil when the host was
  not sent through one (or the exception is unrelated to the proxy path).
  """
  @spec describe_error(Exception.t(), String.t() | nil, t() | nil) :: String.t() | nil
  def describe_error(exception, host, config \\ current()) do
    case route(host, config) do
      :direct -> nil
      {:proxy, _} -> describe(exception, config.endpoint)
    end
  end

  defp describe(%{reason: {:proxy, {:unexpected_status, 407}}}, endpoint),
    do: "proxy #{endpoint} requires authentication"

  defp describe(%{reason: {:proxy, {:unexpected_status, status}}}, endpoint),
    do: "proxy #{endpoint} refused the tunnel (HTTP #{status})"

  defp describe(%{reason: {:proxy, :tunnel_timeout}}, endpoint),
    do: "proxy #{endpoint} did not answer"

  defp describe(%Req.TransportError{reason: reason}, endpoint) when is_atom(reason),
    do: "connection through proxy #{endpoint} failed: #{reason}"

  defp describe(_exception, _endpoint), do: nil
end
