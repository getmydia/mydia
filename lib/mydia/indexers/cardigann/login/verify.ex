defmodule Mydia.Indexers.Cardigann.Login.Verify do
  @moduledoc "Applies a definition's `login.error` and `login.test` blocks to a login response."

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Login.{Http, Inputs}
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @spec check(Parsed.t(), map(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def check(%Parsed{login: login}, response, ctx, base_url) do
    with :ok <- check_status(response),
         :ok <- check_errors(login.error, response.body) do
      check_test(login.test, ctx, base_url)
    end
  end

  defp check_status(%{status: 401}),
    do: {:error, Error.authentication_failed("The tracker rejected the login (HTTP 401)")}

  defp check_status(_), do: :ok

  defp check_errors(errors, _body) when errors in [nil, []], do: :ok

  defp check_errors(errors, body) do
    case Floki.parse_document(body) do
      {:ok, doc} ->
        Enum.find_value(errors, :ok, fn error -> error_result(error, doc) end)

      _ ->
        :ok
    end
  end

  defp error_result(%{selector: selector} = error, doc) when selector not in [nil, ""] do
    case Floki.find(doc, selector) do
      [] ->
        nil

      found ->
        {:error, Error.authentication_failed("Login failed: " <> error_text(error, doc, found))}
    end
  end

  defp error_result(_error, _doc), do: nil

  defp error_text(%{message: %{selector: sel}}, doc, found) when is_binary(sel) and sel != "" do
    case Floki.find(doc, sel) do
      [] -> text(found)
      message -> text(message)
    end
  end

  defp error_text(_error, _doc, found), do: text(found)

  defp text(nodes), do: nodes |> Floki.text() |> String.trim()

  defp check_test(nil, ctx, _base), do: {:ok, ctx}
  defp check_test(%{selector: selector}, ctx, _base) when selector in [nil, ""], do: {:ok, ctx}

  defp check_test(%{selector: selector} = test, ctx, base) do
    with {:ok, resp, ctx} <- Http.request(ctx, :get, Inputs.resolve(base, test[:path] || "/"), []),
         {:ok, doc} <- parse(resp.body) do
      if Floki.find(doc, selector) == [],
        do:
          {:error,
           Error.authentication_failed(
             "Logged in, but the tracker does not show a logged-in page"
           )},
        else: {:ok, ctx}
    end
  end

  defp parse(body) do
    case Floki.parse_document(body) do
      {:ok, doc} ->
        {:ok, doc}

      _ ->
        {:error,
         Error.authentication_failed("The tracker returned an unreadable page after login")}
    end
  end
end
