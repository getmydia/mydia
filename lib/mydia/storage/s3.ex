defmodule Mydia.Storage.S3 do
  @moduledoc "S3-compatible object storage over Req with SigV4."
  @behaviour Mydia.Storage.Backend

  alias Mydia.Storage.{Entry, Error, Location}
  alias Mydia.Storage.S3.Request

  @impl true
  def validate(%Location{backend: b, prefix: prefix}) do
    req = Request.new(b)

    case Req.request(req,
           method: :get,
           url: Request.bucket_url(b),
           params: [{"list-type", "2"}, {"max-keys", "1"}, {"prefix", prefix}]
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> {:error, Request.map_error(other, "s3://#{b.name}/#{prefix}")}
    end
  end

  @impl true
  def list(%Location{} = loc), do: list_page(loc, nil, [])

  defp list_page(%Location{backend: b, prefix: prefix} = loc, token, acc) do
    params =
      [{"list-type", "2"}, {"prefix", prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case Req.request(Request.new(b), method: :get, url: Request.bucket_url(b), params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {contents, next} = Request.parse_list(body)

        entries =
          for %{key: key, size: size, last_modified: lm} <- contents,
              not String.ends_with?(key, "/") do
            %Entry{
              relative_path: String.replace_prefix(key, prefix, ""),
              size: size,
              mtime: Request.parse_time(lm)
            }
          end

        acc = entries ++ acc
        if next, do: list_page(loc, next, acc), else: {:ok, acc}

      other ->
        {:error, Request.map_error(other, "s3://#{b.name}/#{prefix}")}
    end
  end

  @impl true
  def stat(%Location{backend: b} = loc, rel) do
    key = Location.key(loc, rel)

    case Req.request(Request.new(b), method: :head, url: Request.object_url(b, key)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        size =
          resp
          |> Req.Response.get_header("content-length")
          |> List.first("0")
          |> String.to_integer()

        mtime =
          resp |> Req.Response.get_header("last-modified") |> List.first() |> Request.parse_time()

        {:ok, %Entry{relative_path: rel, size: size, mtime: mtime}}

      other ->
        {:error, Request.map_error(other, display(loc, rel))}
    end
  end

  @impl true
  def input(%Location{backend: b} = loc, rel) do
    with {:ok, _} <- stat(loc, rel), do: {:ok, Request.presign(b, Location.key(loc, rel))}
  end

  @impl true
  def read_range(loc, rel, offset, length) do
    case stream_range(loc, rel, offset, length, [], fn chunk, acc -> {:ok, [acc, chunk]} end) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      error -> error
    end
  end

  # Retries are off: a retried request would replay bytes the fold already consumed.
  @impl true
  def stream_range(%Location{backend: b} = loc, rel, offset, length, acc, fun) do
    range = "bytes=#{offset}-#{offset + length - 1}"

    # A provider that ignores Range answers 200 with the whole object. That is
    # only usable from offset 0, and then only up to `length` bytes: the caller
    # has already promised the client exactly that many.
    into = fn {:data, data}, {req, resp} ->
      cond do
        resp.status == 206 or (resp.status == 200 and offset == 0) ->
          feed_range(data, {req, resp}, length, acc, fun)

        resp.status == 200 ->
          {:halt, {req, resp}}

        true ->
          {:cont, {req, resp}}
      end
    end

    result =
      Req.request(Request.new(b, retry: false),
        method: :get,
        url: Request.object_url(b, Location.key(loc, rel)),
        headers: [{"range", range}],
        into: into
      )

    case result do
      {:ok, %Req.Response{status: 200}} when offset > 0 ->
        {:error,
         Error.new(:provider, "provider ignored the Range header for #{display(loc, rel)}")}

      {:ok, %Req.Response{status: s} = resp} when s in [200, 206] ->
        case Req.Response.get_private(resp, :halted) do
          nil -> {:ok, Req.Response.get_private(resp, :acc, acc)}
          reason -> {:error, reason}
        end

      other ->
        {:error, Request.map_error(other, display(loc, rel))}
    end
  end

  # Hands at most `length` bytes in total to the fold, then stops the download.
  defp feed_range(data, {req, resp}, length, acc, fun) do
    seen = Req.Response.get_private(resp, :seen, 0)
    remaining = length - seen
    done? = byte_size(data) >= remaining
    chunk = if done?, do: binary_part(data, 0, remaining), else: data
    resp = Req.Response.put_private(resp, :seen, seen + byte_size(chunk))

    case fun.(chunk, Req.Response.get_private(resp, :acc, acc)) do
      {:ok, next} ->
        resp = Req.Response.put_private(resp, :acc, next)
        if done?, do: {:halt, {req, resp}}, else: {:cont, {req, resp}}

      {:error, reason} ->
        {:halt, {req, Req.Response.put_private(resp, :halted, reason)}}
    end
  end

  defp display(%Location{uri: uri}, rel), do: Path.join(uri, rel)
end
