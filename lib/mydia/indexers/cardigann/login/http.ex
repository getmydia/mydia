defmodule Mydia.Indexers.Cardigann.Login.Http do
  @moduledoc """
  HTTP for Cardigann logins: a cookie jar, the definition's headers, and redirects
  followed one hop at a time.

  Every hop is re-checked before anything is sent: a cleartext non-loopback URL is
  refused, and so is any origin outside `CredentialScope.trusted_origins/2`. Req
  carries a manual Cookie header across a redirect to any host, so redirects are
  never left to Req.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.CredentialScope
  alias Mydia.Indexers.Cardigann.Login.Inputs
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @max_hops 5

  @spec new_ctx(Parsed.t(), map(), [String.t()]) :: map()
  def new_ctx(%Parsed{} = parsed, config, seed_cookies) do
    %{
      jar: put_cookies(%{}, seed_cookies),
      headers: Inputs.headers(parsed, Inputs.context(parsed, config)),
      origins: CredentialScope.trusted_origins(parsed, config),
      max_hops: @max_hops
    }
  end

  @spec cookies(map()) :: [String.t()]
  def cookies(%{jar: jar}), do: Enum.map(jar, fn {k, v} -> k <> "=" <> v end)

  @spec request(map(), :get | :post, String.t(), keyword()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def request(ctx, method, url, opts), do: hop(ctx, method, url, opts, ctx.max_hops)

  defp hop(_ctx, _method, url, _opts, 0),
    do: {:error, Error.connection_failed("Too many redirects during login at #{url}")}

  defp hop(ctx, method, url, opts, hops_left) do
    with :ok <- check_url(ctx, url),
         {:ok, resp} <- send_request(ctx, method, url, opts) do
      ctx = %{ctx | jar: put_cookies(ctx.jar, set_cookies(resp))}

      case {resp.status, location(resp)} do
        {status, loc} when status in 300..399 and is_binary(loc) ->
          # A redirect after a POST becomes a GET, as browsers do.
          hop(ctx, :get, Inputs.resolve_page(url, loc), [], hops_left - 1)

        _ ->
          {:ok, %{status: resp.status, body: body(resp), headers: resp.headers, url: url}, ctx}
      end
    end
  end

  defp check_url(ctx, url) do
    cond do
      CredentialScope.cleartext?(url) ->
        {:error,
         Error.connection_failed(
           "Refusing to send credentials to #{url} over an unencrypted connection. " <>
             "Configure an https link for this indexer."
         )}

      not CredentialScope.allows?(ctx.origins, url) ->
        {:error,
         Error.connection_failed(
           "Login redirected to #{url}, which is not one of this indexer's hosts"
         )}

      true ->
        :ok
    end
  end

  defp send_request(ctx, method, url, opts) do
    req_opts =
      [
        method: method,
        url: url,
        headers: ctx.headers ++ cookie_header(ctx.jar),
        redirect: false,
        retry: false,
        decode_body: false,
        receive_timeout: 30_000
      ] ++ Keyword.take(opts, [:form, :params])

    case Req.request(req_opts) do
      {:ok, %Req.Response{} = resp} ->
        {:ok, resp}

      {:error, exception} ->
        {:error, Error.connection_failed("Login request failed: #{Exception.message(exception)}")}
    end
  rescue
    exception ->
      {:error, Error.connection_failed("Login request failed: #{Exception.message(exception)}")}
  end

  defp cookie_header(jar) when map_size(jar) == 0, do: []

  defp cookie_header(jar),
    do: [{"cookie", Enum.map_join(jar, "; ", fn {k, v} -> k <> "=" <> v end)}]

  defp set_cookies(%Req.Response{} = resp), do: Req.Response.get_header(resp, "set-cookie")

  defp location(%Req.Response{} = resp),
    do: resp |> Req.Response.get_header("location") |> List.first()

  defp body(%Req.Response{body: body}) when is_binary(body), do: body
  defp body(_), do: ""

  @doc """
  Folds cookie strings into a jar of `name => value`.

  `Req.Response.get_header/2` returns one string per `Set-Cookie` header, so
  `"uid=7; Path=/"` yields `uid=7`, while a pasted `"uid=7; pass=abc"` yields both.
  """
  @spec put_cookies(%{String.t() => String.t()}, [String.t()]) :: %{String.t() => String.t()}
  def put_cookies(jar, cookie_strings) do
    Enum.reduce(cookie_strings, jar, fn raw, acc ->
      raw
      |> String.split(";")
      |> Enum.flat_map(&pair/1)
      |> Enum.reduce(acc, fn {k, v}, a -> Map.put(a, k, v) end)
    end)
  end

  # A Set-Cookie header is "name=value; Path=/; ..." and only its first segment is
  # the cookie; a seed or pasted Cookie header is "a=1; b=2" where every segment is.
  # Attribute names never carry a value we want, so keep pairs whose name is not an
  # attribute.
  @attributes ~w(path domain expires max-age secure httponly samesite priority partitioned)
  defp pair(segment) do
    case segment |> String.trim() |> String.split("=", parts: 2) do
      [name, value] when name != "" ->
        if String.downcase(name) in @attributes, do: [], else: [{name, value}]

      _ ->
        []
    end
  end
end
