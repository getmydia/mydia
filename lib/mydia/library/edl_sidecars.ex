defmodule Mydia.Library.EdlSidecars do
  @moduledoc """
  Turns the `.edl` file beside a media file into commercial-break segments.

  DVR tools such as Comskip and MCEBuddy write `Show S01E01.edl` next to
  `Show S01E01.mkv`. The library scan runs `reconcile_all/1` after indexing,
  which stores the file's breaks as `media_segments` rows with
  `type: "commercial"` and `source: "edl"`, replaces them when the sidecar
  changes, and deletes them when it disappears. The player skips them.

  A sidecar belongs only to the media file whose basename it matches exactly,
  extension compared case-insensitively. Breaks are applied at playback by
  seeking, so the media timeline (and subtitle timing) never changes.

  Only `Mydia.Storage.ls/1` and `Mydia.Storage.read_path/1` touch the
  filesystem, so S3 libraries work, and nothing here ever writes, moves or
  deletes the `.edl` file. A failure to list or read keeps the rows already
  stored: a passing network fault must not erase known breaks.
  """

  import Ecto.Query
  require Logger

  alias Mydia.Library.Edl
  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaSegment
  alias Mydia.Repo
  alias Mydia.Storage
  alias Mydia.Subtitles.Sidecars

  @source "edl"
  @type_commercial "commercial"

  @type tally :: %{
          adopted: non_neg_integer(),
          updated: non_neg_integer(),
          reaped: non_neg_integer(),
          errors: [{String.t(), term()}]
        }

  @empty_tally %{adopted: 0, updated: 0, reaped: 0, errors: []}

  @doc """
  Reconciles a library path's media files (with `:library_path` preloaded).
  Called by `Mydia.Jobs.LibraryScanner` after media files are upserted. It
  logs and never raises, so a failure here never fails the scan or stops
  subtitle sidecars from being reconciled.
  """
  @spec reconcile_library(Mydia.Settings.LibraryPath.t(), [MediaFile.t()]) :: :ok
  def reconcile_library(library_path, media_files) do
    tally = reconcile_all(media_files)

    if tally.adopted > 0 or tally.updated > 0 or tally.reaped > 0 do
      Logger.info("EDL sidecars reconciled",
        library_path_id: library_path.id,
        adopted: tally.adopted,
        updated: tally.updated,
        reaped: tally.reaped
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("EDL sidecar reconciliation failed",
        library_path_id: library_path.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  @doc """
  Reconciles every file's EDL segments against the sidecars on disk, listing
  each directory once.

  `adopted` counts files that gained breaks, `updated` files whose breaks
  changed (including to none, for a sidecar with no usable lines), and
  `reaped` files whose sidecar is gone.
  """
  @spec reconcile_all([MediaFile.t()]) :: tally()
  def reconcile_all(media_files) do
    media_files
    |> Enum.group_by(&Sidecars.dir_for/1)
    |> Enum.reduce(@empty_tally, fn
      {nil, _files}, tally ->
        tally

      {dir, files}, tally ->
        case Storage.ls(dir) do
          {:ok, entries} ->
            Enum.reduce(files, tally, &reconcile_file(&1, dir, entries, &2))

          {:error, reason} ->
            Logger.warning("Could not list directory for EDL sidecars",
              dir: dir,
              reason: inspect(reason)
            )

            %{tally | errors: [{dir, reason} | tally.errors]}
        end
    end)
  end

  defp reconcile_file(media_file, dir, entries, tally) do
    existing = existing_ranges(media_file)

    case sidecar_name(media_file, entries) do
      nil when existing == [] ->
        tally

      nil ->
        replace(media_file, [])
        %{tally | reaped: tally.reaped + 1}

      name ->
        path = Path.join(dir, name)

        case Storage.read_path(path) do
          {:ok, content} ->
            apply_ranges(media_file, existing, Edl.parse(content), tally)

          {:error, reason} ->
            Logger.warning("Could not read EDL sidecar", path: path, reason: inspect(reason))
            %{tally | errors: [{path, reason} | tally.errors]}
        end
    end
  end

  defp apply_ranges(_media_file, same, same, tally), do: tally

  defp apply_ranges(media_file, [], ranges, tally) do
    replace(media_file, ranges)
    %{tally | adopted: tally.adopted + 1}
  end

  defp apply_ranges(media_file, _existing, ranges, tally) do
    replace(media_file, ranges)
    %{tally | updated: tally.updated + 1}
  end

  defp sidecar_name(media_file, entries) do
    basename = media_file |> MediaFile.storage_path() |> Sidecars.basename_for()

    Enum.find(entries, fn entry ->
      Path.rootname(entry) == basename and String.downcase(Path.extname(entry)) == ".edl"
    end)
  end

  defp existing_ranges(media_file) do
    Repo.all(
      from(s in edl_segments(media_file),
        order_by: [asc: s.start_ms],
        select: {s.start_ms, s.end_ms}
      )
    )
  end

  defp edl_segments(media_file) do
    from(s in MediaSegment, where: s.media_file_id == ^media_file.id and s.source == @source)
  end

  defp replace(media_file, ranges) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.map(ranges, fn {start_ms, end_ms} ->
        %{
          id: Ecto.UUID.generate(),
          media_file_id: media_file.id,
          type: @type_commercial,
          source: @source,
          start_ms: start_ms,
          end_ms: end_ms,
          confidence: 1.0,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transaction(fn ->
      Repo.delete_all(edl_segments(media_file))
      Repo.insert_all(MediaSegment, rows)
    end)
  end
end
