defmodule Mydia.Storage do
  @moduledoc """
  Library storage: local directories and S3-compatible buckets.

  Read code takes a `Mydia.Storage.Source` and asks this module for bytes, a
  stat, or an `input/1` to hand ffmpeg (an absolute path, or a presigned URL
  for S3). See `lib/mydia/storage/README.md`.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage.{Entry, Error, Location, Source}

  @spec list(Location.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(%Location{} = loc), do: impl(loc).list(loc)

  @spec validate(Location.t()) :: :ok | {:error, Error.t()}
  def validate(%Location{} = loc), do: impl(loc).validate(loc)

  @doc "Checks the backend's credentials and bucket by validating the bucket root."
  @spec test_connection(Mydia.Settings.StorageBackend.t()) :: :ok | {:error, Error.t()}
  def test_connection(backend), do: validate(Location.s3(backend, "", "s3://#{backend.name}"))

  @spec source(Location.t(), String.t()) :: {:ok, Source.t()}
  def source(%Location{} = loc, relative_path) when is_binary(relative_path),
    do: {:ok, Source.new(loc, relative_path)}

  @spec location(LibraryPath.t()) :: {:ok, Location.t()} | {:error, Error.t()}
  def location(%LibraryPath{path: path}) when is_binary(path) do
    if Location.s3_path?(path) do
      with {:ok, name, prefix} <- parse(path),
           backend when not is_nil(backend) <- Settings.get_storage_backend_by_name(name) do
        {:ok, Location.s3(backend, prefix, String.trim_trailing(path, "/"))}
      else
        nil -> {:error, Error.new(:misconfigured, "unknown storage backend in #{path}")}
        {:error, _} = error -> error
      end
    else
      {:ok, Location.local(path)}
    end
  end

  def location(_), do: {:error, Error.new(:not_found, "library path is not set")}

  @doc """
  Resolves a stored path to a `Source`: an absolute local path, or
  `s3://<backend>/<key>`. This is what `MediaFile.storage_path/1`,
  `Subtitle.file_path` and the trash's recorded path hold. An S3 source made
  here is rooted at the bucket (empty prefix), so its relative path is the key.
  """
  @spec at(String.t()) :: {:ok, Source.t()} | {:error, Error.t()}
  def at("s3://" <> _ = uri) do
    with {:ok, name, prefix} <- parse(uri),
         {:key, key} when key != "" <- {:key, String.trim_trailing(prefix, "/")},
         backend when not is_nil(backend) <- Settings.get_storage_backend_by_name(name) do
      {:ok, Source.new(Location.s3(backend, "", "s3://#{name}"), key)}
    else
      {:key, ""} -> {:error, Error.new(:misconfigured, "storage path #{uri} names no object")}
      nil -> {:error, Error.new(:misconfigured, "unknown storage backend in #{uri}")}
      {:error, _} = error -> error
    end
  end

  def at(path) when is_binary(path),
    do: {:ok, Source.new(Location.local(Path.dirname(path)), Path.basename(path))}

  @spec source(MediaFile.t()) :: {:ok, Source.t()} | {:error, Error.t()}
  def source(%MediaFile{relative_path: rel, library_path: %LibraryPath{} = lp})
      when is_binary(rel) do
    with {:ok, loc} <- location(lp), do: source(loc, rel)
  end

  def source(%MediaFile{id: id}),
    do: {:error, Error.new(:not_found, "media file #{id} has no resolvable location")}

  @doc "Source, existence check and `input/1` in one call."
  @spec media_input(MediaFile.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def media_input(%MediaFile{} = mf) do
    with {:ok, source} <- source(mf), do: input(source)
  end

  @doc """
  Maps a `media_input/1` error to the reasons analysis and generation code has
  always returned: `:library_path_not_preloaded` when the media file has no
  resolvable location, `:file_not_found` when the file is missing, and the
  `Error` itself otherwise.
  """
  @spec input_error_reason(Error.t()) ::
          :library_path_not_preloaded | :file_not_found | Error.t()
  def input_error_reason(%Error{kind: :not_found, message: "media file " <> rest} = error) do
    if String.ends_with?(rest, "has no resolvable location"),
      do: :library_path_not_preloaded,
      else: error
  end

  def input_error_reason(%Error{kind: :not_found}), do: :file_not_found
  def input_error_reason(%Error{} = error), do: error

  @spec s3?(LibraryPath.t() | MediaFile.t() | String.t() | nil) :: boolean()
  def s3?(%LibraryPath{path: path}), do: Location.s3_path?(path)
  def s3?(%MediaFile{library_path: %LibraryPath{} = lp}), do: s3?(lp)
  def s3?(path) when is_binary(path), do: Location.s3_path?(path)
  def s3?(_), do: false

  defp parse(path) do
    case Location.parse_s3(path) do
      {:ok, name, prefix} -> {:ok, name, prefix}
      :error -> {:error, Error.new(:misconfigured, "malformed storage path #{path}")}
    end
  end

  @spec stat(Source.t()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def stat(%Source{location: loc, relative_path: rel}), do: impl(loc).stat(loc, rel)

  @spec exists?(Source.t()) :: boolean()
  def exists?(%Source{} = source), do: match?({:ok, _}, stat(source))

  @spec input(Source.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def input(%Source{location: loc, relative_path: rel}), do: impl(loc).input(loc, rel)

  @spec read_range(Source.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def read_range(%Source{location: loc, relative_path: rel}, offset, length),
    do: impl(loc).read_range(loc, rel, offset, length)

  @spec stream_range(Source.t(), non_neg_integer(), pos_integer(), acc, (binary(), acc ->
                                                                           {:ok, acc}
                                                                           | {:error, term()})) ::
          {:ok, acc} | {:error, Error.t() | term()}
        when acc: term()
  def stream_range(%Source{location: loc, relative_path: rel}, offset, length, acc, fun),
    do: impl(loc).stream_range(loc, rel, offset, length, acc, fun)

  @spec put_file(Source.t(), Path.t(), keyword()) :: :ok | {:error, Error.t()}
  def put_file(%Source{location: loc, relative_path: rel}, local_path, opts \\ []),
    do: impl(loc).put_file(loc, rel, local_path, opts)

  @doc """
  Writes `data`. `exclusive: true` refuses an existing file with kind
  `:exists`; otherwise an existing file is replaced atomically. `mkdir: true`
  creates missing local parent directories (S3 has none to create).
  """
  @spec put_binary(Source.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def put_binary(%Source{location: loc, relative_path: rel}, data, opts \\ []),
    do: impl(loc).put_binary(loc, rel, data, opts)

  @spec copy(Source.t(), Source.t()) :: :ok | {:error, Error.t()}
  def copy(%Source{} = from, %Source{} = to) do
    if same_backend?(from.location, to.location),
      do:
        impl(from.location).copy(from.location, from.relative_path, to.location, to.relative_path),
      else: transfer(from, to)
  end

  @doc "Copy then delete. If the delete fails the copy is removed and the error returned."
  @spec move(Source.t(), Source.t()) :: :ok | {:error, Error.t()}
  def move(%Source{} = from, %Source{} = to) do
    if same_backend?(from.location, to.location) do
      impl(from.location).move(from.location, from.relative_path, to.location, to.relative_path)
    else
      with :ok <- transfer(from, to) do
        case delete(from) do
          :ok ->
            :ok

          {:error, _} = error ->
            _ = delete(to)
            error
        end
      end
    end
  end

  @doc "Deletes a file. A file that is already gone is `:ok`."
  @spec delete(Source.t()) :: :ok | {:error, Error.t()}
  def delete(%Source{location: loc, relative_path: rel}), do: impl(loc).delete(loc, rel)

  @doc "Deletes everything under `rel_dir` inside `location`. Never the location itself."
  @spec delete_prefix(Location.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_prefix(%Location{} = loc, rel_dir) do
    segments = rel_dir |> String.trim("/") |> Path.split() |> Enum.reject(&(&1 == ""))

    if segments == [] or Enum.any?(segments, &(&1 in [".", ".."])) do
      {:error, Error.new(:misconfigured, "refusing to delete a whole storage location")}
    else
      impl(loc).delete_prefix(loc, rel_dir)
    end
  end

  @doc """
  Names directly inside the directory at `dir` (a stored path). A listing
  failure is an error, never `{:ok, []}`: callers reconcile against it.
  """
  @spec ls(String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def ls("s3://" <> rest = dir) do
    case String.split(rest, "/", parts: 2) do
      [name] -> ls_at(dir, name, "")
      [name, key] -> ls_at(dir, name, key)
    end
  end

  def ls(dir) when is_binary(dir), do: Mydia.Storage.Local.ls(Location.local(dir), "")

  defp ls_at(dir, name, key) do
    case Settings.get_storage_backend_by_name(name) do
      nil ->
        {:error, Error.new(:misconfigured, "unknown storage backend in #{dir}")}

      backend ->
        loc = Location.s3(backend, "", "s3://#{name}")
        Mydia.Storage.S3.ls(loc, String.trim(key, "/"))
    end
  end

  @spec read(Source.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read(%Source{} = source) do
    with {:ok, %Entry{size: size}} <- stat(source) do
      if size == 0, do: {:ok, ""}, else: read_range(source, 0, size)
    end
  end

  @doc "Copies a file to a local path, creating its directory."
  @spec download(Source.t(), Path.t()) :: :ok | {:error, Error.t()}
  def download(%Source{} = source, local_path) do
    with {:ok, %Entry{size: size}} <- stat(source),
         :ok <- local_mkdir(Path.dirname(local_path)),
         {:ok, io} <- local_open(local_path) do
      result =
        try do
          if size == 0,
            do: {:ok, nil},
            else: stream_range(source, 0, size, nil, &write_chunk(io, local_path, &1, &2))
        after
          File.close(io)
        end

      case result do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          File.rm(local_path)
          {:error, as_error(reason, source)}
      end
    end
  end

  @doc "False for a missing file and for any lookup or storage error."
  @spec path_exists?(String.t()) :: boolean()
  def path_exists?(path) do
    case at(path) do
      {:ok, source} -> exists?(source)
      {:error, _} -> false
    end
  end

  @spec read_path(String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read_path(path), do: with({:ok, source} <- at(path), do: read(source))

  @spec delete_path(String.t()) :: :ok | {:error, Error.t()}
  def delete_path(path), do: with({:ok, source} <- at(path), do: delete(source))

  defp same_backend?(%Location{kind: :local}, %Location{kind: :local}), do: true

  defp same_backend?(%Location{kind: :s3, backend: a}, %Location{kind: :s3, backend: b}),
    do: a.name == b.name

  defp same_backend?(_, _), do: false

  # Between backends a local side is used in place; S3 to S3 goes through a
  # local temp file.
  defp transfer(%Source{location: %Location{kind: :local}} = from, to),
    do: put_file(to, from.path)

  defp transfer(from, %Source{location: %Location{kind: :local}} = to),
    do: download(from, to.path)

  defp transfer(from, to) do
    tmp = Path.join(System.tmp_dir!(), "mydia-transfer-#{System.unique_integer([:positive])}")

    try do
      with :ok <- download(from, tmp), do: put_file(to, tmp)
    after
      File.rm(tmp)
    end
  end

  defp local_mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.from_posix(reason, dir)}
    end
  end

  defp local_open(path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end

  defp write_chunk(io, path, chunk, acc) do
    case :file.write(io, chunk) do
      :ok -> {:ok, acc}
      {:error, reason} -> {:error, Error.from_posix(reason, path)}
    end
  end

  defp as_error(%Error{} = error, _source), do: error

  defp as_error(other, source),
    do: Error.new(:provider, "#{inspect(other)} reading #{source.path}")

  @doc "Strips the query string (presigned credentials) from a URL. Paths pass through."
  @spec redact(String.t() | nil) :: String.t() | nil
  def redact("http" <> _ = url), do: url |> URI.parse() |> Map.put(:query, nil) |> URI.to_string()
  def redact(other), do: other

  @doc """
  Renders a term for logging with every URL query string removed. Tool output
  (ffmpeg stderr, error tuples) can echo the presigned input URL.
  """
  @spec redact_text(term()) :: String.t()
  def redact_text(text) when is_binary(text),
    do: Regex.replace(~r/(https?:\/\/[^\s'"?]+)\?[^\s'"]*/, text, "\\1")

  def redact_text(term), do: term |> inspect() |> redact_text()

  defp impl(%Location{kind: :local}), do: Mydia.Storage.Local
  defp impl(%Location{kind: :s3}), do: Mydia.Storage.S3
end
