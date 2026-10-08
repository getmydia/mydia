defmodule Mydia.Storage.S3 do
  @moduledoc "S3-compatible object storage over Req with SigV4."
  @behaviour Mydia.Storage.Backend

  alias Mydia.Storage.{Entry, Error, Location}
  alias Mydia.Storage.S3.{Multipart, Request}

  @part_size 64 * 1024 * 1024
  @copy_threshold 5 * 1024 * 1024 * 1024
  @copy_part_size 512 * 1024 * 1024

  defp setting(key, default),
    do: :mydia |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  # Req raises on a URL it cannot parse (no scheme or host), so every entry
  # point checks the endpoint first and never reaches Req with a bad one.
  @impl true
  def validate(%Location{backend: b} = loc) do
    with :ok <- Request.check(b), do: do_validate(loc)
  end

  defp do_validate(%Location{backend: b, prefix: prefix}) do
    req = Request.new(b)

    case Req.request(req,
           method: :get,
           url:
             Request.bucket_query_url(b, [
               {"list-type", "2"},
               {"max-keys", "1"},
               {"prefix", prefix}
             ])
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> {:error, Request.map_error(other, "s3://#{b.name}/#{prefix}")}
    end
  end

  @impl true
  def list(%Location{backend: b, prefix: prefix}) do
    trash = Mydia.Library.TrashStore.dir_name()

    with :ok <- Request.check(b),
         {:ok, objects} <- list_objects(b, prefix, false) do
      entries =
        objects
        |> Enum.reject(&String.ends_with?(&1.key, "/"))
        |> Enum.map(fn %{key: key, size: size, last_modified: lm} ->
          %Entry{
            relative_path: String.replace_prefix(key, prefix, ""),
            size: size,
            mtime: Request.parse_time(lm)
          }
        end)
        # Mirrors Local.walk: the trash lives inside the library prefix on S3.
        |> Enum.reject(&(trash in Path.split(&1.relative_path)))

      {:ok, entries}
    end
  end

  # Every object under `key_prefix`, following continuation tokens. With
  # `delimiter?` only the objects directly under it (no "subdirectories").
  defp list_objects(b, key_prefix, delimiter?),
    do: list_objects(b, key_prefix, delimiter?, nil, [])

  defp list_objects(b, key_prefix, delimiter?, token, acc) do
    params =
      [{"list-type", "2"}, {"prefix", key_prefix}] ++
        if(delimiter?, do: [{"delimiter", "/"}], else: []) ++
        if(token, do: [{"continuation-token", token}], else: [])

    case Req.request(Request.new(b), method: :get, url: Request.bucket_query_url(b, params)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {contents, next} = Request.parse_list(body)
        acc = acc ++ contents
        if next, do: list_objects(b, key_prefix, delimiter?, next, acc), else: {:ok, acc}

      other ->
        {:error, Request.map_error(other, "s3://#{b.name}/#{key_prefix}")}
    end
  end

  @impl true
  def stat(%Location{backend: b} = loc, rel) do
    with :ok <- Request.check(b), do: do_stat(loc, rel)
  end

  defp do_stat(%Location{backend: b} = loc, rel) do
    key = Location.key(loc, rel)

    case Req.request(Request.new(b), method: :head, url: Request.object_url(b, key)) do
      {:ok, %Req.Response{status: 200} = resp} ->
        with {:ok, size} <- content_length(resp, display(loc, rel)) do
          mtime =
            resp
            |> Req.Response.get_header("last-modified")
            |> List.first()
            |> Request.parse_time()

          {:ok, %Entry{relative_path: rel, size: size, mtime: mtime}}
        end

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

  @impl true
  def put_file(%Location{backend: b} = loc, rel, local_path, opts) do
    part_size = Keyword.get_lazy(opts, :part_size, fn -> setting(:part_size, @part_size) end)
    key = Location.key(loc, rel)
    what = display(loc, rel)

    with :ok <- Request.check(b),
         {:ok, %File.Stat{size: size}} <- local_stat(local_path) do
      if size <= part_size do
        with {:ok, body} <- read_local(local_path), do: put_object(b, key, body, [], what)
      else
        Multipart.upload(b, key, local_path, size, part_size, what)
      end
    end
  end

  @impl true
  def put_binary(%Location{backend: b} = loc, rel, data, opts) do
    exclusive? = Keyword.get(opts, :exclusive, false)

    with :ok <- Request.check(b),
         :ok <- if(exclusive?, do: refuse_existing(loc, rel), else: :ok) do
      headers = if exclusive?, do: [{"if-none-match", "*"}], else: []
      put_object(b, Location.key(loc, rel), IO.iodata_to_binary(data), headers, display(loc, rel))
    end
  end

  @impl true
  def copy(%Location{backend: b} = from, from_rel, %Location{} = to, to_rel) do
    from_key = Location.key(from, from_rel)
    to_key = Location.key(to, to_rel)
    what = display(from, from_rel)

    with :ok <- Request.check(b),
         {:ok, %Entry{size: size}} <- stat(from, from_rel) do
      # CopyObject stops at 5 GB.
      if size > setting(:copy_threshold, @copy_threshold),
        do:
          Multipart.copy(
            b,
            from_key,
            to_key,
            size,
            setting(:copy_part_size, @copy_part_size),
            what
          ),
        else: copy_object(b, from_key, to_key, what)
    end
  end

  defp local_stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end

  @impl true
  def move(from, from_rel, to, to_rel) do
    with :ok <- copy(from, from_rel, to, to_rel) do
      case delete(from, from_rel) do
        :ok ->
          :ok

        {:error, _} = error ->
          _ = delete(to, to_rel)
          error
      end
    end
  end

  @impl true
  def delete(%Location{backend: b} = loc, rel) do
    with :ok <- Request.check(b) do
      case Req.request(Request.new(b),
             method: :delete,
             url: Request.object_url(b, Location.key(loc, rel))
           ) do
        {:ok, %Req.Response{status: s}} when s in [200, 204, 404] -> :ok
        other -> {:error, Request.map_error(other, display(loc, rel))}
      end
    end
  end

  @impl true
  def delete_prefix(%Location{backend: b} = loc, rel_dir) do
    with :ok <- Request.check(b),
         {:ok, objects} <- list_objects(b, dir_prefix(loc, rel_dir), false) do
      objects
      |> Enum.map(& &1.key)
      |> Enum.chunk_every(1000)
      |> Enum.reduce_while(:ok, fn keys, :ok ->
        case delete_batch(b, keys) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @impl true
  def ls(%Location{backend: b} = loc, rel_dir) do
    prefix = dir_prefix(loc, rel_dir)

    with :ok <- Request.check(b),
         {:ok, objects} <- list_objects(b, prefix, true) do
      {:ok,
       objects
       |> Enum.reject(&String.ends_with?(&1.key, "/"))
       |> Enum.map(&String.replace_prefix(&1.key, prefix, ""))}
    end
  end

  defp dir_prefix(%Location{prefix: prefix}, rel_dir) when rel_dir in ["", ".", "/"], do: prefix

  defp dir_prefix(%Location{} = loc, rel_dir),
    do: Location.key(loc, String.trim(rel_dir, "/")) <> "/"

  # If-None-Match is honored by AWS and current RustFS and MinIO, and ignored
  # by some providers. The HEAD covers those in the common, non-racing case.
  # Observed against RustFS: a second PUT with `If-None-Match: *` on an existing
  # key answers 412, which put_object/5 maps to :exists as well.
  defp refuse_existing(loc, rel) do
    case stat(loc, rel) do
      {:ok, _} -> {:error, Error.new(:exists, "already exists: #{display(loc, rel)}")}
      {:error, %Error{kind: :not_found}} -> :ok
      {:error, _} = error -> error
    end
  end

  defp put_object(b, key, body, headers, what) do
    case Req.request(Request.new(b),
           method: :put,
           url: Request.object_url(b, key),
           headers: headers,
           body: body
         ) do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: 412}} -> {:error, Error.new(:exists, "already exists: #{what}")}
      other -> {:error, Request.map_error(other, what)}
    end
  end

  defp copy_object(b, from_key, to_key, what) do
    case Req.request(Request.new(b, receive_timeout: Request.long_timeout()),
           method: :put,
           url: Request.object_url(b, to_key),
           headers: [{"x-amz-copy-source", Request.copy_source(b, from_key)}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        if Request.error_body?(body),
          do: {:error, Error.new(:provider, "S3 could not copy #{what}")},
          else: :ok

      other ->
        {:error, Request.map_error(other, what)}
    end
  end

  defp delete_batch(b, keys) do
    body = Request.delete_objects_body(keys)

    case Req.request(Request.new(b),
           method: :post,
           url: Request.bucket_url(b),
           params: [{"delete", ""}],
           headers: [
             {"content-md5", Request.content_md5(body)},
             {"content-type", "application/xml"}
           ],
           body: body
         ) do
      {:ok, %Req.Response{status: 200, body: resp}} ->
        if Request.error_body?(resp),
          do: {:error, Error.new(:provider, "S3 refused to delete some objects in #{b.name}")},
          else: :ok

      other ->
        {:error, Request.map_error(other, "s3://#{b.name}")}
    end
  end

  defp read_local(path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end

  # Retries are off: a retried request would replay bytes the fold already consumed.
  @impl true
  def stream_range(%Location{backend: b} = loc, rel, offset, length, acc, fun) do
    with :ok <- Request.check(b), do: do_stream_range(loc, rel, offset, length, acc, fun)
  end

  defp do_stream_range(%Location{backend: b} = loc, rel, offset, length, acc, fun) do
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
          # Caller fold errors pass through unchanged.
          nil -> finish_range(resp, length, acc, display(loc, rel))
          reason -> {:error, reason}
        end

      other ->
        {:error, Request.map_error(other, display(loc, rel))}
    end
  end

  # The response ended without the caller halting it: a body shorter than the
  # promised length is a provider fault, not a smaller success.
  defp finish_range(resp, length, acc, display) do
    if Req.Response.get_private(resp, :seen, 0) < length do
      {:error, Error.new(:provider, "unexpected end of stream for #{display}")}
    else
      {:ok, Req.Response.get_private(resp, :acc, acc)}
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

  # Never raise on a provider's header: anything but a plain non-negative
  # integer is a provider fault.
  defp content_length(resp, display) do
    value = resp |> Req.Response.get_header("content-length") |> List.first("0")

    case Integer.parse(value) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, Error.new(:provider, "invalid content-length from provider for #{display}")}
    end
  end

  defp display(%Location{uri: uri}, rel), do: Path.join(uri, rel)
end
