defmodule MydiaWeb.Api.RangeHelper do
  @moduledoc """
  Helper functions for handling HTTP Range requests.

  Supports parsing Range headers and generating appropriate response headers
  for HTTP 206 Partial Content responses.
  """

  import Plug.Conn,
    only: [get_req_header: 2, put_resp_header: 3, put_status: 2, send_file: 3, send_file: 5]

  @doc """
  Parses an HTTP Range header value.

  Returns {:ok, start, end_pos} for valid ranges or :error for invalid ones.
  Only supports single byte ranges in the format "bytes=START-END" or "bytes=START-".

  ## Examples

      iex> parse_range_header("bytes=0-499", 1000)
      {:ok, 0, 499}

      iex> parse_range_header("bytes=500-", 1000)
      {:ok, 500, 999}

      iex> parse_range_header("bytes=invalid", 1000)
      :error
  """
  def parse_range_header(nil, _file_size), do: :error
  def parse_range_header("", _file_size), do: :error

  def parse_range_header(range_header, file_size) do
    # Only support single byte range requests
    case String.split(range_header, "=") do
      ["bytes", range_spec] ->
        parse_range_spec(range_spec, file_size)

      _ ->
        :error
    end
  end

  defp parse_range_spec(spec, file_size) do
    case String.split(spec, "-") do
      [start_str, ""] ->
        # Range like "bytes=500-" (from position to end)
        with {start, ""} <- Integer.parse(start_str),
             true <- start >= 0 and start < file_size do
          {:ok, start, file_size - 1}
        else
          _ -> :error
        end

      [start_str, end_str] ->
        # Range like "bytes=0-499"
        with {start, ""} <- Integer.parse(start_str),
             {end_pos, ""} <- Integer.parse(end_str),
             true <- start >= 0 and start <= end_pos and end_pos < file_size do
          {:ok, start, end_pos}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Calculates the byte range to serve based on start and end positions.

  Returns {offset, length} tuple where:
  - offset: byte position to start reading from
  - length: number of bytes to read

  ## Examples

      iex> calculate_range(0, 499)
      {0, 500}

      iex> calculate_range(500, 999)
      {500, 500}
  """
  def calculate_range(start, end_pos) when start <= end_pos do
    {start, end_pos - start + 1}
  end

  @doc """
  Formats a Content-Range header value.

  ## Examples

      iex> format_content_range(0, 499, 1000)
      "bytes 0-499/1000"

      iex> format_content_range(500, 999, 1000)
      "bytes 500-999/1000"
  """
  def format_content_range(start, end_pos, total) do
    "bytes #{start}-#{end_pos}/#{total}"
  end

  @doc """
  Gets MIME type from file extension.

  ## Examples

      iex> get_mime_type("/path/to/movie.mp4")
      "video/mp4"

      iex> get_mime_type("/path/to/movie.mkv")
      "video/x-matroska"
  """
  def get_mime_type(path) do
    extension =
      path
      |> Path.extname()
      |> String.downcase()

    case extension do
      ".mp4" -> "video/mp4"
      ".m4v" -> "video/x-m4v"
      ".mkv" -> "video/x-matroska"
      ".avi" -> "video/x-msvideo"
      ".webm" -> "video/webm"
      ".mov" -> "video/quicktime"
      ".wmv" -> "video/x-ms-wmv"
      ".flv" -> "video/x-flv"
      ".ts" -> "video/mp2t"
      _ -> "video/mp4"
    end
  end

  @doc """
  Sends `file_path` honouring a single-range `Range` header.

  Answers 206 for a valid range, 200 with the whole file when there is no
  Range header, and 416 when the header is present but unusable. The caller
  must have checked that the file exists.
  """
  @spec send_file_ranged(Plug.Conn.t(), Path.t()) :: Plug.Conn.t()
  def send_file_ranged(conn, file_path) do
    file_size = File.stat!(file_path).size
    mime_type = get_mime_type(file_path)
    range_header = conn |> get_req_header("range") |> List.first()

    case parse_range_header(range_header, file_size) do
      {:ok, start, end_pos} ->
        {offset, length} = calculate_range(start, end_pos)

        conn
        |> put_status(:partial_content)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-range", format_content_range(start, end_pos, file_size))
        |> put_resp_header("content-length", to_string(length))
        |> put_resp_header("x-streaming-mode", "direct")
        |> send_file(:partial_content, file_path, offset, length)

      :error when is_nil(range_header) ->
        conn
        |> put_status(:ok)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-length", to_string(file_size))
        |> put_resp_header("x-streaming-mode", "direct")
        |> send_file(:ok, file_path)

      :error ->
        conn
        |> put_status(:requested_range_not_satisfiable)
        |> put_resp_header("content-range", "bytes */#{file_size}")
        |> Phoenix.Controller.json(%{error: "Invalid range request"})
    end
  end
end
