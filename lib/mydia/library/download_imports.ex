defmodule Mydia.Library.DownloadImports do
  @moduledoc """
  Lookups that tie media files back to the downloads they were imported from.
  """

  import Ecto.Query, warn: false
  import Mydia.DB
  import Mydia.QueryHelpers
  alias Mydia.Repo
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata

  @doc """
  Checks if a torrent from a download client has already been imported to the library.

  Returns true if any media_file has this client_id in its metadata, false otherwise.
  This is used to prevent re-processing torrents that are seeding after import.
  """
  @spec torrent_already_imported?(String.t(), String.t()) :: boolean()
  def torrent_already_imported?(client_name, client_id) do
    query =
      from f in MediaFile,
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client", client_name),
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client_id", client_id)

    Repo.exists?(query)
  end

  @doc """
  Batched `torrent_already_imported?/2`: which of `pairs` are already imported.

  `pairs` are `{client_name, client_id}` tuples. Returns the subset found in
  `media_files` provenance, as a MapSet for membership testing.

  Checking one pair at a time costs a query each, which the external-torrent
  scan pays on every pass over every foreign torrent in every client. This
  filters server-side by the exact pairs asked about, so the rows it loads are
  bounded by the candidates rather than by library size.

  Chunked because the filter is an OR-chain of pair conditions and SQLite caps
  expression depth; the chunk size keeps the generated SQL well inside it.
  """
  @spec imported_torrent_pairs([{String.t(), String.t()}]) :: MapSet.t({String.t(), String.t()})
  def imported_torrent_pairs([]), do: MapSet.new()

  def imported_torrent_pairs(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.chunk_every(100)
    |> Enum.reduce(MapSet.new(), fn chunk, acc ->
      chunk
      |> imported_pairs_chunk()
      |> MapSet.union(acc)
    end)
  end

  defp imported_pairs_chunk(chunk) do
    condition =
      Enum.reduce(chunk, dynamic(false), fn {client_name, client_id}, acc ->
        dynamic(
          ^acc or
            (^Mydia.DB.json_equals(:metadata, "$.download_client", client_name) and
               ^Mydia.DB.json_equals(:metadata, "$.download_client_id", client_id))
        )
      end)

    wanted = MapSet.new(chunk)

    from(f in MediaFile, where: ^condition, select: f.metadata)
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn metadata, acc ->
      # download_client / download_client_id are not declared FileMetadata
      # fields, so they live in the `extra` catch-all.
      extra = (metadata && metadata.extra) || %{}
      pair = {extra["download_client"], extra["download_client_id"]}

      if MapSet.member?(wanted, pair), do: MapSet.put(acc, pair), else: acc
    end)
  end

  @doc """
  The download a media file was imported from, or `nil`.

  Resolves the `imported_from_download_id` provenance key that
  `Mydia.Jobs.MediaImport` writes into the file's metadata at import time.
  This is the inverse of `list_media_files_for_download/2` and uses the same
  key, which is the download's primary key and therefore collision-free.

  Returns `nil` for a scanner-discovered file, which never carries the key, and
  for a file whose download row has since been cleared.
  """
  @spec origin_download(MediaFile.t()) :: Mydia.Downloads.Download.t() | nil
  def origin_download(%MediaFile{metadata: %FileMetadata{extra: extra}}) when is_map(extra) do
    case extra["imported_from_download_id"] do
      id when is_binary(id) -> Repo.get(Mydia.Downloads.Download, id)
      _ -> nil
    end
  end

  def origin_download(%MediaFile{}), do: nil

  @doc """
  Lists the media files imported from a given download.

  Located by the collision-free `imported_from_download_id` provenance key — the
  download's primary key, written into `metadata` at import time. The
  `(download_client, download_client_id)` pair is deliberately NOT used as the
  key: download clients recycle torrent/nzb IDs, so that pair is unique only at a
  single instant, not over the file's lifetime, and would surface the wrong file.

  Excludes trashed files. Pass `preload:` to preload associations.
  """
  @spec list_media_files_for_download(Mydia.Downloads.Download.t(), keyword()) :: [MediaFile.t()]
  def list_media_files_for_download(download, opts \\ []) do
    query =
      from f in MediaFile,
        where: ^Mydia.DB.json_equals(:metadata, "$.imported_from_download_id", download.id),
        where: is_nil(f.trashed_at)

    query
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Counts non-trashed imported files per download, keyed by `imported_from_download_id`.

  Batched companion to `list_media_files_for_download/1` for callers that need to
  know how many files a set of downloads imported without an N+1 query — e.g. the
  Downloads LiveView deciding whether a completed row is single-file (re-match
  eligible) or a pack. Returns `%{download_id => count}`; downloads with no
  imported files are simply absent from the map.
  """
  @spec count_imported_files_by_download([binary()]) :: %{binary() => non_neg_integer()}
  def count_imported_files_by_download([]), do: %{}

  def count_imported_files_by_download(download_ids) when is_list(download_ids) do
    ids = Enum.map(download_ids, &to_string/1)

    from(f in MediaFile,
      where: is_nil(f.trashed_at),
      where: json_extract(f.metadata, "$.imported_from_download_id") in ^ids,
      group_by: json_extract(f.metadata, "$.imported_from_download_id"),
      select: {json_extract(f.metadata, "$.imported_from_download_id"), count(f.id)}
    )
    |> Repo.all()
    |> Map.new()
  end
end
