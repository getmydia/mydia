defmodule Mydia.Net.ProxyAdapter do
  @moduledoc """
  The Req adapter that sends outbound requests through the configured proxy.

  Installed once at application start as the global Req `:adapter`
  (`Req.default_options/1`), unconditionally. With no proxy configured it is a
  pass-through to `Req.Finch`, so a config change never requires reinstalling
  it: routing reads `Mydia.Net.Proxy.current/0` on every request.

  For each request it:

    1. leaves `connect_options` alone when they already carry `:proxy`, or when
       the caller named its own Finch pool with `:finch` (Req refuses
       `:finch` together with `:connect_options`);
    2. goes direct when the URL host is a private or loopback IP literal, even
       with `:hostname` set: the SSRF gate pins approved plugin endpoints (which
       may live on the LAN) to their resolved IP, and a proxy cannot reach those;
    3. otherwise routes on the effective host, `connect_options[:hostname]` when
       set (the SSRF gate pins the URL to a validated IP and passes the real name
       there), else the URL host, and merges `proxy:` and `proxy_headers:` into
       `connect_options` when `Mydia.Net.Proxy.route/2` says to proxy;
    4. delegates to `Req.Finch.run/1`, which keeps proxied connections in their
       own Finch pool.

  Requests that set their own `adapter:` or `plug:` (`Req.Test`) never reach it.
  """

  alias Mydia.Net.Proxy
  alias Mydia.Net.Proxy.Bypass
  alias Mydia.Plugins.Net.Gate

  @doc "Req adapter callback."
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  def run(%Req.Request{} = request) do
    request
    |> apply_proxy(Proxy.current())
    |> Req.Finch.run()
  end

  @doc false
  @spec apply_proxy(Req.Request.t(), Proxy.t() | nil) :: Req.Request.t()
  def apply_proxy(request, nil), do: request

  def apply_proxy(%Req.Request{options: options} = request, config) do
    connect_options = Map.get(options, :connect_options, [])

    cond do
      Keyword.has_key?(connect_options, :proxy) ->
        request

      Map.get(options, :finch) ->
        request

      pinned_private?(request.url.host) ->
        request

      true ->
        host = Keyword.get(connect_options, :hostname) || request.url.host

        case Proxy.route(host, config) do
          :direct ->
            request

          {:proxy, proxy_opts} ->
            Req.Request.put_option(
              request,
              :connect_options,
              Keyword.merge(connect_options, proxy_opts)
            )
        end
    end
  end

  # The URL host is what Mint connects to. When it is a private or loopback IP
  # literal (an approved plugin endpoint pinned by the gate, with the real name
  # in :hostname), the proxy cannot reach it, so the request goes direct.
  defp pinned_private?(host) when is_binary(host) do
    case Bypass.host_ip(Bypass.normalize_host(host)) do
      nil -> false
      ip -> not Gate.public_ip?(ip)
    end
  end

  defp pinned_private?(_host), do: false
end
