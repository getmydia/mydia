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
        nil -> {:error, Error.new(:not_found, "unknown storage backend in #{path}")}
        {:error, _} = error -> error
      end
    else
      {:ok, Location.local(path)}
    end
  end

  def location(_), do: {:error, Error.new(:not_found, "library path is not set")}

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

  @spec ensure_writable(LibraryPath.t() | MediaFile.t() | String.t() | nil) ::
          :ok | {:error, Error.t()}
  def ensure_writable(target) do
    if s3?(target),
      do: {:error, Error.new(:read_only, "S3 libraries are read-only in this version of Mydia")},
      else: :ok
  end

  defp parse(path) do
    case Location.parse_s3(path) do
      {:ok, name, prefix} -> {:ok, name, prefix}
      :error -> {:error, Error.new(:not_found, "malformed storage path #{path}")}
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
