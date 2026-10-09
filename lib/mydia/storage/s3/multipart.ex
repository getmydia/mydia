defmodule Mydia.Storage.S3.Multipart do
  @moduledoc false
  # Multipart upload and multipart copy. An object becomes visible only on
  # CompleteMultipartUpload, so any failure aborts and leaves nothing behind.
  # Each part is one signed request with a binary body, which Req's
  # `retry: :transient` can safely resend. Up to `concurrency` parts are in
  # flight at once, so an upload holds up to that many parts in memory.

  alias Mydia.Storage.Error
  alias Mydia.Storage.S3.Request

  @spec upload(
          struct(),
          String.t(),
          Path.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) :: :ok | {:error, Error.t()}
  def upload(b, key, local_path, size, part_size, concurrency, what) do
    with {:ok, upload_id} <- initiate(b, key, what) do
      result =
        each_part(size, part_size, concurrency, fn {n, offset, len} ->
          with {:ok, data} <- read_part(local_path, offset, len),
               do: upload_part(b, key, upload_id, n, data, what)
        end)

      finish(b, key, upload_id, result, what)
    end
  end

  @spec copy(
          struct(),
          String.t(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t()
        ) :: :ok | {:error, Error.t()}
  def copy(b, from_key, to_key, size, part_size, concurrency, what) do
    with {:ok, upload_id} <- initiate(b, to_key, what) do
      result =
        each_part(size, part_size, concurrency, fn {n, offset, len} ->
          copy_part(b, from_key, to_key, upload_id, n, offset, len, what)
        end)

      finish(b, to_key, upload_id, result, what)
    end
  end

  # Halting on the first error shuts down the parts still in flight before
  # this returns, so no request of ours is running when finish/5 aborts. A
  # part the provider already received may still land after the abort; the
  # provider discards it with the upload, or lifecycle rules reap it.
  defp each_part(size, part_size, concurrency, fun) do
    0
    |> Stream.iterate(&(&1 + part_size))
    |> Stream.take_while(&(&1 < size))
    |> Stream.with_index(1)
    |> Task.async_stream(
      fn {offset, n} ->
        with {:ok, etag} <- fun.({n, offset, min(part_size, size - offset)}),
             do: {:ok, {n, etag}}
      end,
      max_concurrency: concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, part}}, {:ok, acc} -> {:cont, {:ok, [part | acc]}}
      {:ok, {:error, _} = error}, _ -> {:halt, error}
    end)
  end

  defp finish(b, key, upload_id, {:ok, parts}, what) do
    case complete(b, key, upload_id, Enum.reverse(parts), what) do
      :ok ->
        :ok

      {:error, _} = error ->
        abort(b, key, upload_id)
        error
    end
  end

  defp finish(b, key, upload_id, {:error, _} = error, _what) do
    abort(b, key, upload_id)
    error
  end

  defp initiate(b, key, what) do
    case Req.request(Request.new(b),
           method: :post,
           url: Request.object_url(b, key),
           params: [{"uploads", ""}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Request.parse_upload_id(body) do
          nil -> {:error, Error.new(:provider, "S3 returned no upload id for #{what}")}
          id -> {:ok, id}
        end

      other ->
        {:error, Request.map_error(other, what)}
    end
  end

  defp upload_part(b, key, upload_id, n, data, what) do
    case Req.request(Request.new(b, receive_timeout: Request.long_timeout()),
           method: :put,
           url: Request.object_url(b, key),
           params: [{"partNumber", Integer.to_string(n)}, {"uploadId", upload_id}],
           body: data
         ) do
      {:ok, %Req.Response{status: 200} = resp} ->
        case Req.Response.get_header(resp, "etag") do
          [etag | _] -> {:ok, etag}
          [] -> {:error, Error.new(:provider, "S3 returned no ETag for part #{n} of #{what}")}
        end

      other ->
        {:error, Request.map_error(other, what)}
    end
  end

  defp copy_part(b, from_key, to_key, upload_id, n, offset, len, what) do
    case Req.request(Request.new(b, receive_timeout: Request.long_timeout()),
           method: :put,
           url: Request.object_url(b, to_key),
           params: [{"partNumber", Integer.to_string(n)}, {"uploadId", upload_id}],
           headers: [
             {"x-amz-copy-source", Request.copy_source(b, from_key)},
             {"x-amz-copy-source-range", "bytes=#{offset}-#{offset + len - 1}"}
           ]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case {Request.error_body?(body), Request.parse_etag(body)} do
          {false, etag} when is_binary(etag) -> {:ok, etag}
          _ -> {:error, Error.new(:provider, "S3 could not copy part #{n} of #{what}")}
        end

      other ->
        {:error, Request.map_error(other, what)}
    end
  end

  defp complete(b, key, upload_id, parts, what) do
    case Req.request(Request.new(b, receive_timeout: Request.long_timeout()),
           method: :post,
           url: Request.object_url(b, key),
           params: [{"uploadId", upload_id}],
           headers: [{"content-type", "application/xml"}],
           body: Request.complete_body(parts)
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        if Request.error_body?(body),
          do: {:error, Error.new(:provider, "S3 could not assemble #{what}")},
          else: :ok

      other ->
        {:error, Request.map_error(other, what)}
    end
  end

  # Best effort: a failed abort leaves an incomplete upload the provider's
  # lifecycle rules reap. It is never visible as an object.
  defp abort(b, key, upload_id) do
    _ =
      Req.request(Request.new(b),
        method: :delete,
        url: Request.object_url(b, key),
        params: [{"uploadId", upload_id}]
      )

    :ok
  end

  # A raw handle works only in the process that opened it, so each part task
  # opens its own.
  defp read_part(path, offset, len) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          case :file.pread(io, offset, len) do
            {:ok, data} when byte_size(data) == len -> {:ok, data}
            {:ok, _short} -> {:error, Error.new(:provider, "#{path} changed size during upload")}
            :eof -> {:error, Error.new(:provider, "#{path} changed size during upload")}
            {:error, reason} -> {:error, Error.from_posix(reason, path)}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, Error.from_posix(reason, path)}
    end
  end
end
