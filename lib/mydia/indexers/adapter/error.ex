defmodule Mydia.Indexers.Adapter.Error do
  @moduledoc """
  Error types for indexer operations.

  This module defines a consistent error structure for all indexer adapters
  to use when returning errors.

  ## Error Types

    * `:connection_failed` - Unable to connect to the indexer
    * `:authentication_failed` - Invalid API key or authentication error
    * `:timeout` - Request timed out
    * `:rate_limited` - Rate limit exceeded
    * `:search_failed` - Search query failed
    * `:parse_error` - Error parsing response from indexer
    * `:invalid_config` - Invalid configuration provided
    * `:api_error` - Generic API error from the indexer
    * `:network_error` - Network-related error
    * `:not_found` - Resource not found
    * `:unknown` - Unknown or unexpected error

  ## Examples

      iex> Error.new(:connection_failed, "Connection refused")
      %Error{type: :connection_failed, message: "Connection refused", details: nil}

      iex> Error.new(:rate_limited, "Rate limit exceeded", %{retry_after: 60})
      %Error{type: :rate_limited, message: "Rate limit exceeded", details: %{retry_after: 60}}

      iex> Error.rate_limited("Too many requests", %{retry_after: 120})
      %Error{type: :rate_limited, message: "Too many requests", details: %{retry_after: 120}}
  """

  @type error_type ::
          :connection_failed
          | :authentication_failed
          | :timeout
          | :rate_limited
          | :search_failed
          | :parse_error
          | :invalid_config
          | :api_error
          | :network_error
          | :not_found
          | :unknown

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          details: map() | nil
        }

  defexception [:type, :message, :details]

  @doc """
  Creates a new error struct.

  ## Examples

      iex> Error.new(:connection_failed, "Connection refused")
      %Error{type: :connection_failed, message: "Connection refused", details: nil}

      iex> Error.new(:api_error, "Bad request", %{status: 400})
      %Error{type: :api_error, message: "Bad request", details: %{status: 400}}
  """
  @spec new(error_type(), String.t(), map() | nil) :: t()
  def new(type, message, details \\ nil) do
    %__MODULE__{
      type: type,
      message: message,
      details: details
    }
  end

  @doc """
  Creates a connection failed error.

  ## Examples

      iex> Error.connection_failed("Connection refused")
      %Error{type: :connection_failed, message: "Connection refused", details: nil}
  """
  @spec connection_failed(String.t(), map() | nil) :: t()
  def connection_failed(message, details \\ nil) do
    new(:connection_failed, message, details)
  end

  @doc """
  Creates an authentication failed error.

  ## Examples

      iex> Error.authentication_failed("Invalid API key")
      %Error{type: :authentication_failed, message: "Invalid API key", details: nil}
  """
  @spec authentication_failed(String.t(), map() | nil) :: t()
  def authentication_failed(message, details \\ nil) do
    new(:authentication_failed, message, details)
  end

  @doc """
  Creates a timeout error.

  ## Examples

      iex> Error.timeout("Request timed out after 30s")
      %Error{type: :timeout, message: "Request timed out after 30s", details: nil}
  """
  @spec timeout(String.t(), map() | nil) :: t()
  def timeout(message, details \\ nil) do
    new(:timeout, message, details)
  end

  @doc """
  Creates a rate limited error.

  ## Examples

      iex> Error.rate_limited("Rate limit exceeded", %{retry_after: 60})
      %Error{type: :rate_limited, message: "Rate limit exceeded", details: %{retry_after: 60}}
  """
  @spec rate_limited(String.t(), map() | nil) :: t()
  def rate_limited(message, details \\ nil) do
    new(:rate_limited, message, details)
  end

  @doc """
  Creates a search failed error.

  ## Examples

      iex> Error.search_failed("No results found")
      %Error{type: :search_failed, message: "No results found", details: nil}
  """
  @spec search_failed(String.t(), map() | nil) :: t()
  def search_failed(message, details \\ nil) do
    new(:search_failed, message, details)
  end

  @doc """
  Creates a parse error.

  ## Examples

      iex> Error.parse_error("Invalid XML response")
      %Error{type: :parse_error, message: "Invalid XML response", details: nil}
  """
  @spec parse_error(String.t(), map() | nil) :: t()
  def parse_error(message, details \\ nil) do
    new(:parse_error, message, details)
  end

  @doc """
  Creates an invalid config error.

  ## Examples

      iex> Error.invalid_config("Missing required field: api_key")
      %Error{type: :invalid_config, message: "Missing required field: api_key", details: nil}
  """
  @spec invalid_config(String.t(), map() | nil) :: t()
  def invalid_config(message, details \\ nil) do
    new(:invalid_config, message, details)
  end

  @doc """
  Creates an API error.

  ## Examples

      iex> Error.api_error("Bad request", %{status: 400})
      %Error{type: :api_error, message: "Bad request", details: %{status: 400}}
  """
  @spec api_error(String.t(), map() | nil) :: t()
  def api_error(message, details \\ nil) do
    new(:api_error, message, details)
  end

  @doc """
  Creates a network error.

  ## Examples

      iex> Error.network_error("DNS resolution failed")
      %Error{type: :network_error, message: "DNS resolution failed", details: nil}
  """
  @spec network_error(String.t(), map() | nil) :: t()
  def network_error(message, details \\ nil) do
    new(:network_error, message, details)
  end

  @doc """
  Creates a not found error.

  ## Examples

      iex> Error.not_found("Indexer not found")
      %Error{type: :not_found, message: "Indexer not found", details: nil}
  """
  @spec not_found(String.t(), map() | nil) :: t()
  def not_found(message, details \\ nil) do
    new(:not_found, message, details)
  end

  @doc """
  Creates an unknown error.

  ## Examples

      iex> Error.unknown("Unexpected error occurred")
      %Error{type: :unknown, message: "Unexpected error occurred", details: nil}
  """
  @spec unknown(String.t(), map() | nil) :: t()
  def unknown(message, details \\ nil) do
    new(:unknown, message, details)
  end

  @doc """
  Converts a Req error to an indexer adapter error.

  ## Examples

      iex> Error.from_req_error(%Req.TransportError{reason: :econnrefused})
      %Error{type: :connection_failed, message: "Connection refused", details: nil}

      iex> Error.from_req_error(%Req.Response{status: 401})
      %Error{type: :authentication_failed, message: "Authentication failed (401)", details: %{status: 401}}

      iex> Error.from_req_error(%Req.Response{status: 429})
      %Error{type: :rate_limited, message: "Rate limit exceeded (429)", details: %{status: 429}}
  """
  @spec from_req_error(Exception.t() | Req.Response.t()) :: t()
  def from_req_error(%Req.TransportError{reason: :econnrefused}) do
    connection_failed("Connection refused")
  end

  def from_req_error(%Req.TransportError{reason: :timeout}) do
    timeout("Request timed out")
  end

  def from_req_error(%Req.TransportError{reason: :nxdomain}) do
    network_error("DNS resolution failed")
  end

  def from_req_error(%Req.TransportError{reason: reason}) do
    connection_failed("Transport error: #{inspect(reason)}")
  end

  def from_req_error(%Req.Response{status: 401}) do
    authentication_failed("Authentication failed (401)", %{status: 401})
  end

  def from_req_error(%Req.Response{status: 403}) do
    authentication_failed("Access forbidden (403)", %{status: 403})
  end

  def from_req_error(%Req.Response{status: 404}) do
    not_found("Resource not found (404)", %{status: 404})
  end

  def from_req_error(%Req.Response{status: 429} = response) do
    retry_after = get_retry_after(response)
    details = %{status: 429, retry_after: retry_after}
    rate_limited("Rate limit exceeded (429)", details)
  end

  def from_req_error(%Req.Response{status: status} = response) when status >= 400 do
    api_error("HTTP #{status}", %{status: status, body: response.body})
  end

  def from_req_error(error) do
    unknown("Unexpected error: #{inspect(error)}", %{error: error})
  end

  @doc """
  Returns a human-readable error message.

  ## Examples

      iex> error = Error.connection_failed("Connection refused")
      iex> Error.message(error)
      "Connection failed: Connection refused"
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{type: type, message: msg}) do
    type_label =
      type
      |> Atom.to_string()
      |> String.replace("_", " ")
      |> String.capitalize()

    "#{type_label}: #{msg}"
  end

  # Exception behaviour implementation
  @impl true
  def exception(opts) when is_list(opts) do
    type = Keyword.get(opts, :type, :unknown)
    message = Keyword.get(opts, :message, "An error occurred")
    details = Keyword.get(opts, :details)

    new(type, message, details)
  end

  def exception(message) when is_binary(message) do
    new(:unknown, message, nil)
  end

  # Private helpers

  defp get_retry_after(%Req.Response{headers: headers}) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(key) == "retry-after", do: parse_retry_after(value)
    end)
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _} -> seconds
      :error -> nil
    end
  end

  defp parse_retry_after(_), do: nil
end
