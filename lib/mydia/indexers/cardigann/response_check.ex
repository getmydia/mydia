defmodule Mydia.Indexers.Cardigann.ResponseCheck do
  @moduledoc """
  Classifies a Cardigann search response's HTTP status before the result
  parser sees it: an unfollowed redirect, an authentication failure, a 429
  carrying its `Retry-After`, or a server or client error.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannSearchEngine

  require Logger

  @doc """
  Validates the HTTP response before passing to the result parser.

  Checks for common error conditions:
  - Rate limiting (429)
  - Authentication errors (401, 403)
  - Server errors (5xx)
  - Invalid response format

  ## Returns

  - `:ok` - Response is valid and ready for parsing
  - `{:error, reason}` - Response indicates an error

  ## Examples

      iex> validate_response(%{status: 200, body: "<html>...</html>"})
      :ok

      iex> validate_response(%{status: 429, body: "Rate limit exceeded"})
      {:error, %Error{type: :rate_limited}}
  """
  @spec validate_response(CardigannSearchEngine.http_response()) :: :ok | {:error, Error.t()}

  # An unfollowed redirect used to land in the catch-all below as
  # "Unexpected status: 302", which told an operator nothing about where the
  # indexer was trying to send them. This is now only reachable when a
  # definition sets `followredirect: false`, since search follows by default.
  #
  # Task 5's retryable_failure?/1 matches on the "Redirected (HTTP " prefix.
  def validate_response(%{status: status} = response) when status in 300..399 do
    location = response |> Map.get(:headers) |> location_header()

    suffix = if location, do: " to #{location}", else: " with no Location header"

    {:error,
     Error.search_failed("Redirected (HTTP #{status})#{suffix} and the redirect was not followed")}
  end

  def validate_response(%{status: status, body: body} = response) do
    cond do
      status == 200 ->
        :ok

      status == 401 || status == 403 ->
        {:error, Error.connection_failed("Authentication failed")}

      status == 429 ->
        retry_after = Error.retry_after_ms(Map.get(response, :headers) || [])
        {:error, Error.rate_limited("Rate limit exceeded", %{retry_after: retry_after})}

      status >= 500 ->
        {:error, Error.search_failed("Server error: HTTP #{status}")}

      status >= 400 ->
        Logger.warning("Cardigann search returned HTTP #{status}: #{inspect(body)}")
        {:error, Error.search_failed("HTTP #{status}")}

      true ->
        Logger.warning("Unexpected HTTP status: #{status}")
        {:error, Error.search_failed("Unexpected status: #{status}")}
    end
  end

  @doc """
  The `Location` header's value, or nil. Req 0.5 returns headers as a map of
  lowercase name to a list of values; older shapes and hand-built test
  responses use a keyword-ish list.
  """
  @spec location_header(map() | list() | nil) :: String.t() | nil
  def location_header(headers) when is_map(headers) do
    case Map.get(headers, "location") do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def location_header(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {name, value} -> if String.downcase(to_string(name)) == "location", do: value
      _ -> nil
    end)
  end

  def location_header(_), do: nil
end
