defmodule Mydia.Indexers.Cardigann.Login.Simple do
  @moduledoc "The `cookie`, `get` and `post` login methods, as Prowlarr's DoLogin runs them."

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login.{Http, Inputs, Session, Verify}

  @spec run(atom(), map()) :: {:ok, Session.t()} | {:error, Error.t()}
  def run(:cookie, %{config: config}) do
    case Map.get(config, "cookie") do
      value when is_binary(value) and value != "" ->
        jar = Http.put_cookies(%{}, [value])
        {:ok, %Session{method: :cookie, cookies: Http.cookies(%{jar: jar})}}

      _ ->
        {:error,
         Error.authentication_failed(
           "Paste the Cookie header from a logged-in browser into this indexer's cookie setting"
         )}
    end
  end

  def run(method, %{parsed: parsed, config: config, base: base}) when method in [:get, :post] do
    context = Inputs.context(parsed, config)
    ctx = Http.new_ctx(parsed, config, parsed.login.cookies)

    with {:ok, path} <- Inputs.render(parsed.login.path, context),
         {:ok, params} <- Inputs.render_map(parsed.login.inputs, context),
         {:ok, resp, ctx} <-
           Http.request(ctx, method, Inputs.resolve(base, path), request_body(method, params)),
         {:ok, ctx} <- Verify.check(parsed, resp, ctx, base) do
      {:ok, %Session{method: method, cookies: Http.cookies(ctx)}}
    end
  end

  defp request_body(:get, params), do: [params: params]
  defp request_body(:post, params), do: [form: params]
end
