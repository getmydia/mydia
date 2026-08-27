defmodule Mydia.Subtitles.Uploader do
  @moduledoc """
  Stores a subtitle file a user uploaded from the web UI.

  Mirrors `Mydia.Subtitles.Downloader`'s storage convention exactly
  (`\#{media_basename}.\#{language}.\#{format}`, written beside the media
  file) so an uploaded file is indistinguishable from a downloaded one to
  every other tool that reads the directory, including this codebase's own
  `Mydia.Subtitles.Sidecars` reconciliation, which would otherwise see it as
  a brand new sidecar to adopt on the next rescan.

  Unlike a search result, an uploaded file's format is not declared by
  anything trustworthy: the filename extension `allow_upload`'s `accept`
  option checks is entirely client-controlled. The real gate is
  `Mydia.Subtitles.Format.detect/1`, run on the bytes actually received, the
  same function `Downloader` and `Sidecars` both already trust for the same
  reason.
  """

  require Logger

  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Subtitles.Format
  alias Mydia.Subtitles.Sidecars
  alias Mydia.Subtitles.Subtitle

  # Ecto.Changeset.unique_constraint/3 attaches a composite constraint's
  # error to the FIRST field named ([:media_file_id, :subtitle_hash]), not
  # to :subtitle_hash, so insert_error_message/1 below matches on the
  # constraint name itself rather than a field.
  @duplicate_content_constraint "subtitles_media_file_id_subtitle_hash_index"

  @doc """
  Stores `content` as a subtitle for `media_file`.

  `media_file` must already have its `library_path` association preloaded;
  callers already need that to resolve the file's location for display, so
  this does not repeat the query.

  ## Options

  - `:language` - required, an ISO 639-1 code
  - `:forced` - defaults to `false`
  - `:hearing_impaired` - defaults to `false`

  Returns `{:ok, subtitle}` or `{:error, message}`, where `message` is a
  `String.t()` safe to show an operator directly.

  Refuses rather than overwrites when the destination path already exists on
  disk (delete the existing track first), and refuses rather than silently
  redirects when `media_file` is not the file that would own a sidecar at
  that path. Predictable beats clever in both cases, since the outcome is a
  write into someone's library. See "Identical basenames" below for the
  second case.

  Nothing is written to disk before the destination is confirmed free and
  owned by `media_file`; nothing is inserted before the write to disk
  succeeds; the file is removed if the insert then fails (typically a
  byte-identical subtitle already recorded for this media file). Every
  failure path here leaves either both the row and the file, or neither.

  ## Identical basenames

  When a directory holds two media files that reduce to the exact same
  basename (`Movie.mkv` beside `Movie.mp4`, one title in two containers),
  `Mydia.Subtitles.Sidecars.reconcile/1` attributes their shared sidecar to
  whichever one `Mydia.Library.FileRanking.best/1` ranks higher, never to
  both: name matching alone cannot tell the two apart. Uploading against the
  other file would create a row a later reconcile pass disagrees with:
  reconcile sees the same path as unclaimed from the winning file's point of
  view and adopts it a second time, leaving two rows pointing at one file.
  Deleting either row then deletes a file the other still legitimately
  references. This is checked, via `Mydia.Subtitles.Sidecars.owning_media_file_for/2`,
  before anything is written, and refused with the name of the file to
  retry against instead.
  """
  @spec upload(MediaFile.t(), binary(), keyword()) ::
          {:ok, Subtitle.t()} | {:error, String.t()}
  def upload(%MediaFile{} = media_file, content, opts) when is_binary(content) do
    language = Keyword.fetch!(opts, :language)
    forced = Keyword.get(opts, :forced, false)
    hearing_impaired = Keyword.get(opts, :hearing_impaired, false)

    with {:ok, format} <- detect_format(content),
         {:ok, path} <- destination(media_file, language, format),
         :ok <- check_ownership(media_file, path),
         :ok <- write(path, content) do
      insert(media_file, path, language, format, content, forced, hearing_impaired)
    end
  end

  ## Private

  defp detect_format(content) do
    case Format.detect(content) do
      {:ok, format} ->
        {:ok, format}

      {:error, {:unsupported_subtitle_format, other}} ->
        {:error, "That file is a #{other} subtitle, which Mydia cannot read"}

      {:error, :unrecognized_subtitle_content} ->
        {:error, "That file is not a subtitle Mydia can read"}
    end
  end

  # Matches Downloader's convention exactly, so an uploaded file is
  # indistinguishable from a downloaded one to anything else reading the
  # directory. An existing path is refused rather than auto-suffixed:
  # predictable beats clever when the result is a file written into
  # someone's library.
  defp destination(media_file, language, format) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        {:error, "Could not resolve where that media file lives on disk"}

      absolute_path ->
        path = "#{Path.rootname(absolute_path)}.#{language}.#{format}"

        if File.exists?(path) do
          {:error, "There is already a subtitle for that language. Delete it first."}
        else
          {:ok, path}
        end
    end
  end

  defp check_ownership(media_file, path) do
    filename = Path.basename(path)

    case Sidecars.owning_media_file_for(media_file, filename) do
      nil ->
        :ok

      owner ->
        if owner.id == media_file.id do
          :ok
        else
          {:error,
           "#{MediaFile.display_name(media_file)} shares its filename with " <>
             "#{MediaFile.display_name(owner)} in the same folder, and only one of them " <>
             "can own this subtitle. Upload it from #{MediaFile.display_name(owner)} instead."}
        end
    end
  end

  # No temp file, unlike Downloader: the bytes already live in memory (read
  # from the LiveView upload's own temp path, which Phoenix removes once
  # consumed), so there is nothing to rename or clean up here beyond the
  # final path itself. mkdir_p mirrors Downloader's defensive call, but
  # deliberately the non-raising form: the media directory normally already
  # exists (the video file lives there), so this never actually attempts a
  # write; File.write/2 below is what surfaces a read-only mount, and it
  # returns an error tuple rather than raising.
  defp write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      :ok
    else
      {:error, reason} -> {:error, write_error_message(path, reason)}
    end
  end

  defp write_error_message(path, reason) when reason in [:eacces, :erofs] do
    "Cannot write to #{Path.dirname(path)}. That library path is read-only."
  end

  defp write_error_message(_path, reason) do
    "Could not write the subtitle file: #{inspect(reason)}"
  end

  defp insert(media_file, path, language, format, content, forced, hearing_impaired) do
    %Subtitle{}
    |> Subtitle.changeset(%{
      media_file_id: media_file.id,
      language: language,
      provider: "upload",
      origin: "upload",
      forced: forced,
      hearing_impaired: hearing_impaired,
      subtitle_hash: hash(content),
      file_path: path,
      format: format
    })
    |> Repo.insert()
    |> case do
      {:ok, subtitle} ->
        {:ok, subtitle}

      {:error, changeset} ->
        File.rm(path)

        Logger.warning("Subtitle upload not saved",
          media_file_id: media_file.id,
          errors: inspect(changeset.errors)
        )

        {:error, insert_error_message(changeset)}
    end
  end

  # The unique index on (media_file_id, subtitle_hash) is the only
  # validation on this changeset that a caller of upload/3 can actually
  # trigger: format is already known-good from detect_format/1, language and
  # the two flags are never user-typed strings. Anything else reaching this
  # branch is unexpected, so it gets a generic message rather than a
  # misleading claim of duplicate content.
  defp insert_error_message(changeset) do
    duplicate? =
      Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == @duplicate_content_constraint
      end)

    if duplicate? do
      "Mydia already has a subtitle with identical content for this file"
    else
      "Could not save that subtitle: #{inspect(changeset.errors)}"
    end
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
