defmodule Mydia.Storage.S3.Multipart do
  @moduledoc false
  # Multipart upload and multipart copy. An object becomes visible only on
  # CompleteMultipartUpload, so any failure aborts and leaves nothing behind.
  # Each part is one signed request with a binary body, which Req's
  # `retry: :transient` can safely resend.

  alias Mydia.Storage.Error
  alias Mydia.Storage.S3.Request

  # A 512 MiB part, a part copy or a Complete on a huge object keeps the
  # connection open well past the default 30s while the provider works.
  @part_timeout 10 * 60_000

  @spec upload(struct(), String.t(), Path.t(), non_neg_integer(), pos_integer(), String.t()) ::
          :ok | {:error, Error.t()}
  def upload(b, key, local_path, size, part_size, what) do
    with {:ok, upload_id} <- initiate(b, key, what) do
      result =
        case File.open(local_path, [:read, :binary, :raw]) do
          {:ok, io} ->
            try do
              each_part(size, part_size, fn {n, offset, len} ->
                with {:ok, data} <- pread(io, offset, len, local_path),
                     do: upload_part(b, key, upload_id, n, data, what)
              end)
            after
              File.close(io)
            end

          {:error, reason} ->
            {:error, Error.from_posix(reason, local_path)}
        end

      finish(b, key, upload_id, result, what)
    end
  end

  @spec copy(struct(), String.t(), String.t(), non_neg_integer(), pos_integer(), String.t()) ::
          :ok | {:error, Error.t()}
  def copy(b, from_key, to_key, size, part_size, what) do
    with {:ok, upload_id} <- initiate(b, to_key, what) do
      result =
        each_part(size, part_size, fn {n, offset, len} ->
          copy_part(b, from_key, to_key, upload_id, n, offset, len, what)
        end)

      finish(b, to_key, upload_id, result, what)
    end
  end

  defp each_part(size, part_size, fun) do
    0
    |> Stream.iterate(&(&1 + part_size))
    |> Stream.take_while(&(&1 < size))
    |> Stream.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {offset, n}, {:ok, acc} ->
      case fun.({n, offset, min(part_size, size - offset)}) do
        {:ok, etag} -> {:cont, {:ok, [{n, etag} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
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
    case Req.request(Request.new(b, receive_timeout: @part_timeout),
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
    case Req.request(Request.new(b, receive_timeout: @part_timeout),
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
    case Req.request(Request.new(b, receive_timeout: @part_timeout),
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

  defp pread(io, offset, len, path) do
    case :file.pread(io, offset, len) do
      {:ok, data} when byte_size(data) == len -> {:ok, data}
      {:ok, _short} -> {:error, Error.new(:provider, "#{path} changed size during upload")}
      :eof -> {:error, Error.new(:provider, "#{path} changed size during upload")}
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end
end
