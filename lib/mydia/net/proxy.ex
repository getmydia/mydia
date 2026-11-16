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

  # -- effective config ------------------------------------------------------

  @doc """
  Resolves the effective proxy from the layered config and standard env vars.

  Returns `{:ok, nil}` when no proxy is configured.
  """
  @spec effective(ProxyConfig.t() | nil, (String.t() -> String.t() | nil)) ::
          {:ok, t() | nil} | {:error, String.t()}
  def effective(proxy_config, getenv) when is_function(getenv, 1) do
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
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) ->
        {:ok,
         %__MODULE__{
           proxy: {String.to_existing_atom(scheme), host, port, []},
           headers: auth_headers(uri.userinfo),
           display_url: display_url(scheme, host, port, uri.userinfo),
           endpoint: "#{host}:#{port}",
           url_from: source
         }}

      %URI{scheme: scheme}
      when is_binary(scheme) and scheme not in ["http", "https"] ->
        if String.contains?(url, "://") do
          {:error, "unsupported proxy URL in #{label}: #{scheme} is not supported"}
        else
          invalid_url(label)
        end

      _ ->
        invalid_url(label)
    end
  end

  defp invalid_url(label),
    do: {:error, "invalid proxy URL in #{label}: expected http://host:port or https://host:port"}

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
        info -> elem(split_userinfo(info), 0) <> ":****@"
      end

    "#{scheme}://#{credentials}#{host}:#{port}"
  end

  # -- cached config ---------------------------------------------------------

  @doc "Stores the effective config (or nil) for request-time routing."
  @spec put_config(t() | nil) :: :ok
  def put_config(config), do: :persistent_term.put(@config_key, config)

  @doc "The cached effective config, or nil when unset."
  @spec current() :: t() | nil
  def current, do: :persistent_term.get(@config_key, nil)

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

  defp describe(%Req.TransportError{reason: reason}, endpoint) when is_atom(reason),
    do: "connection through proxy #{endpoint} failed: #{reason}"

  defp describe(_exception, _endpoint), do: nil
end
