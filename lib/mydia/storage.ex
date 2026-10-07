defmodule Mydia.Storage do
  @moduledoc """
  Library storage: local directories and S3-compatible buckets.

  Read code takes a `Mydia.Storage.Source` and asks this module for bytes, a
  stat, or an `input/1` to hand ffmpeg (an absolute path, or a presigned URL
  for S3). See `lib/mydia/storage/README.md`.
  """

  alias Mydia.Storage.{Entry, Error, Location, Source}

  @spec list(Location.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(%Location{} = loc), do: impl(loc).list(loc)

  @spec validate(Location.t()) :: :ok | {:error, Error.t()}
  def validate(%Location{} = loc), do: impl(loc).validate(loc)

  @spec source(Location.t(), String.t()) :: {:ok, Source.t()}
  def source(%Location{} = loc, relative_path) when is_binary(relative_path),
    do: {:ok, Source.new(loc, relative_path)}

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

  defp impl(%Location{kind: :local}), do: Mydia.Storage.Local
  defp impl(%Location{kind: :s3}), do: Mydia.Storage.S3
end
