defmodule Mydia.Downloads.Client.Error do
  @moduledoc """
  Error types for download client operations.

  This module defines a consistent error structure for all download client
  adapters to use when returning errors.

  ## Error Types

    * `:connection_failed` - Unable to connect to the download client
    * `:authentication_failed` - Invalid credentials or authentication error
    * `:timeout` - Request timed out
    * `:not_found` - Torrent or resource not found
    * `:invalid_torrent` - Invalid torrent file or magnet link
    * `:duplicate_torrent` - Torrent already exists in the client
    * `:insufficient_space` - Not enough disk space
    * `:invalid_config` - Invalid configuration provided
    * `:api_error` - Generic API error from the client
    * `:network_error` - Network-related error
    * `:parse_error` - Error parsing response from client
    * `:stale_session` - Internal marker: the client session expired and the caller should re-authenticate
    * `:unknown` - Unknown or unexpected error

  ## Examples

      iex> Error.new(:connection_failed, "Connection refused")
      %Error{type: :connection_failed, message: "Connection refused", details: nil}

      iex> Error.new(:api_error, "Invalid request", %{status: 400})
      %Error{type: :api_error, message: "Invalid request", details: %{status: 400}}

      iex> Error.connection_failed("Timeout after 30s")
      %Error{type: :connection_failed, message: "Timeout after 30s", details: nil}
  """

  @type error_type ::
          :connection_failed
          | :authentication_failed
          | :timeout
          | :not_found
          | :invalid_torrent
          | :duplicate_torrent
          | :insufficient_space
          | :invalid_config
          | :api_error
          | :network_error
          | :parse_error
          | :stale_session
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

      iex> Error.authentication_failed("Invalid username or password")
      %Error{type: :authentication_failed, message: "Invalid username or password", details: nil}
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
  Creates a not found error.

  ## Examples

      iex> Error.not_found("Torrent not found")
      %Error{type: :not_found, message: "Torrent not found", details: nil}
  """
  @spec not_found(String.t(), map() | nil) :: t()
  def not_found(message, details \\ nil) do
    new(:not_found, message, details)
  end

  @doc """
  Creates an invalid torrent error.

  ## Examples

      iex> Error.invalid_torrent("Invalid magnet link format")
      %Error{type: :invalid_torrent, message: "Invalid magnet link format", details: nil}
  """
  @spec invalid_torrent(String.t(), map() | nil) :: t()
  def invalid_torrent(message, details \\ nil) do
    new(:invalid_torrent, message, details)
  end

  @doc """
  Creates a duplicate torrent error.

  ## Examples

      iex> Error.duplicate_torrent("Torrent already exists")
      %Error{type: :duplicate_torrent, message: "Torrent already exists", details: nil}
  """
  @spec duplicate_torrent(String.t(), map() | nil) :: t()
  def duplicate_torrent(message, details \\ nil) do
    new(:duplicate_torrent, message, details)
  end

  @doc """
  Creates an insufficient space error.

  ## Examples

      iex> Error.insufficient_space("Not enough disk space")
      %Error{type: :insufficient_space, message: "Not enough disk space", details: nil}
  """
  @spec insufficient_space(String.t(), map() | nil) :: t()
  def insufficient_space(message, details \\ nil) do
    new(:insufficient_space, message, details)
  end

  @doc """
  Creates an invalid config error.

  ## Examples

      iex> Error.invalid_config("Missing required field: host")
      %Error{type: :invalid_config, message: "Missing required field: host", details: nil}
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
  Creates a parse error.

  ## Examples

      iex> Error.parse_error("Invalid JSON response")
      %Error{type: :parse_error, message: "Invalid JSON response", details: nil}
  """
  @spec parse_error(String.t(), map() | nil) :: t()
  def parse_error(message, details \\ nil) do
    new(:parse_error, message, details)
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
  Converts a Req error to a download client error.

  ## Examples

      iex> Error.from_req_error(%Req.TransportError{reason: :econnrefused})
      %Error{type: :connection_failed, message: "Connection refused", details: nil}

      iex> Error.from_req_error(%Req.Response{status: 401})
      %Error{type: :authentication_failed, message: "Authentication failed (401)", details: %{status: 401}}
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
end
