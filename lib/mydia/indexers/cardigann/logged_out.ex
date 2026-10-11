defmodule Mydia.Indexers.Cardigann.LoggedOut do
  @moduledoc """
  Decides whether a search response came back as a logged-out visitor.

  Follows Prowlarr's CheckIfLoginIsNeeded, applied only to requests that carried
  our session cookies: the search engine never follows a cookie-bearing redirect,
  so any redirect means the tracker sent us to its login page.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @spec check(Parsed.t(), tuple(), boolean()) :: :ok | :logged_out
  def check(_parsed, _result, false), do: :ok
  def check(%Parsed{login: nil}, _result, _sent), do: :ok

  def check(_parsed, {:error, %Error{message: "Redirected (HTTP 3" <> _}}, true),
    do: :logged_out

  def check(
        _parsed,
        {:error, %Error{type: :connection_failed, message: "Authentication failed"}},
        true
      ),
      do: :logged_out

  def check(%Parsed{login: %{test: %{selector: selector}}}, {:ok, %{body: body} = resp}, true)
      when is_binary(selector) and is_binary(body) do
    if html?(resp) and missing?(body, selector), do: :logged_out, else: :ok
  end

  def check(parsed, {:ok, response, _extra}, sent), do: check(parsed, {:ok, response}, sent)
  def check(_parsed, _result, _sent), do: :ok

  defp html?(%{headers: headers}) when is_map(headers) do
    content_type =
      headers
      |> Map.new(fn {k, v} -> {String.downcase(to_string(k)), List.wrap(v)} end)
      |> Map.get("content-type")

    case content_type do
      [type | _] -> String.contains?(type, "html")
      _ -> true
    end
  end

  defp html?(_), do: true

  defp missing?(body, selector) do
    case Floki.parse_document(body) do
      {:ok, doc} -> Floki.find(doc, selector) == []
      _ -> false
    end
  end
end
