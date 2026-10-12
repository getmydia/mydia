defmodule Mydia.Indexers.Cardigann.Login.Verify do
  @moduledoc "Applies a definition's `login.error` and `login.test` blocks to a login response."

  require Logger

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.{Charset, Selector}
  alias Mydia.Indexers.Cardigann.Login.{Http, Inputs}
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @spec check(Parsed.t(), map(), map(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def check(%Parsed{login: login} = parsed, response, ctx, base_url) do
    with :ok <- check_status(response),
         :ok <- check_errors(login.error, response.body, parsed) do
      check_test(login.test, parsed, ctx, base_url)
    end
  end

  defp check_status(%{status: 401}),
    do: {:error, Error.authentication_failed("The tracker rejected the login (HTTP 401)")}

  defp check_status(_), do: :ok

  defp check_errors(errors, _body, _parsed) when errors in [nil, []], do: :ok

  defp check_errors(errors, body, parsed) when is_binary(body) do
    document = Selector.parse(Charset.decode(body, parsed.encoding), error_selectors(errors))
    Enum.find_value(errors, :ok, fn error -> error_result(error, document) end)
  rescue
    # A selector lexbor rejects says nothing about the page, so it is not a login failure.
    error in ArgumentError ->
      if Selector.selector_error?(error) do
        Logger.warning(
          "Cardigann #{parsed.id}: login error selector ignored: #{Exception.message(error)}"
        )

        :ok
      else
        reraise error, __STACKTRACE__
      end
  end

  defp check_errors(_errors, _body, _parsed), do: :ok

  # Every selector goes to Selector.parse/2 up front so `:contains` needles are declared.
  defp error_selectors(errors) do
    Enum.flat_map(errors, fn error -> [error[:selector], get_in(error, [:message, :selector])] end)
  end

  defp error_result(%{selector: selector} = error, document) when selector not in [nil, ""] do
    case Selector.find(document, :root, selector) do
      [] ->
        nil

      found ->
        {:error,
         Error.authentication_failed("Login failed: " <> error_text(error, document, found))}
    end
  end

  defp error_result(_error, _document), do: nil

  defp error_text(%{message: %{selector: sel}}, document, found)
       when is_binary(sel) and sel != "" do
    case Selector.find(document, :root, sel) do
      [] -> text(found)
      message -> text(message)
    end
  end

  defp error_text(_error, _document, found), do: text(found)

  defp text(nodes), do: nodes |> Selector.text() |> String.trim()

  defp check_test(nil, _parsed, ctx, _base), do: {:ok, ctx}

  defp check_test(%{selector: selector}, _parsed, ctx, _base) when selector in [nil, ""],
    do: {:ok, ctx}

  defp check_test(%{selector: selector} = test, parsed, ctx, base) do
    with {:ok, resp, ctx} <- Http.request(ctx, :get, Inputs.resolve(base, test[:path] || "/"), []),
         {:ok, found?} <- test_selector_matches?(resp.body, parsed, selector) do
      if found?,
        do: {:ok, ctx},
        else:
          {:error,
           Error.authentication_failed(
             "Logged in, but the tracker does not show a logged-in page"
           )}
    end
  end

  defp test_selector_matches?(body, parsed, selector) do
    document =
      body |> to_string() |> Charset.decode(parsed.encoding) |> Selector.parse([selector])

    {:ok, Selector.find(document, :root, selector) != []}
  rescue
    error in ArgumentError ->
      if Selector.selector_error?(error) do
        {:error,
         Error.authentication_failed(
           "Invalid login test selector in the #{parsed.id} definition: #{Exception.message(error)}"
         )}
      else
        reraise error, __STACKTRACE__
      end
  end
end
