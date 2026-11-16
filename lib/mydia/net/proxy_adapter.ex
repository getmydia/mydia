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
    2. otherwise routes on the effective host, `connect_options[:hostname]` when
       set (the SSRF gate pins the URL to a validated IP and passes the real name
       there), else the URL host, and merges `proxy:` and `proxy_headers:` into
       `connect_options` when `Mydia.Net.Proxy.route/2` says to proxy;
    3. delegates to `Req.Finch.run/1`, which keeps proxied connections in their
       own Finch pool.

  Requests that set their own `adapter:` or `plug:` (`Req.Test`) never reach it.
  """

  alias Mydia.Net.Proxy

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
end
