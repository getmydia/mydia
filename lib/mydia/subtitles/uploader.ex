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

  `:language` is validated against a strict code-shaped pattern before it
  touches any path. It arrives here from an HTML `<select>` in the web UI,
  but that constrains nothing at this boundary: a `phx-submit` payload sent
  directly over the socket can carry any string, and `destination/3` below
  interpolates `:language` straight into a file path. An unvalidated value
  is a path traversal primitive, not a display string, and
  `check_ownership/2`'s sidecar-ownership check does not defend against
  that: it prefix-matches the resulting basename against real siblings, so
  a traversal payload simply matches none of them and is waved through.
  Containment is `validate_language/1`'s job alone, enforced before
  `destination/3` ever runs.

  Nothing is written to disk before the destination is confirmed free,
  owned by `media_file` (see "Identical basenames"), and reachable only
  through a language code that cannot contain a path separator; nothing is
  inserted before the write to disk succeeds; the file is removed if the
  insert then fails (typically a byte-identical subtitle already recorded
  for this media file). Every failure path here leaves either both the row
  and the file, or neither. The directory `write/3` ensures exists is
  always the media file's own directory from the database, never derived
  from the computed destination path, so even a caller that reached
  `destination/3` some other way without going through the language check
  could not use a crafted path to make this function create directories it
  should not.

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

    with :ok <- validate_language(language),
         {:ok, format} <- detect_format(content),
         {:ok, path} <- destination(media_file, language, format),
         :ok <- check_ownership(media_file, path),
         :ok <- write(media_file, path, content) do
      insert(media_file, path, language, format, content, forced, hearing_impaired)
    end
  end

  ## Private

  # The security boundary for what this function will write to disk, not a
  # display concern: `destination/3` builds a file path by interpolating
  # `language` raw, with no `Path.join`, no `..`/`/` rejection, and no
  # length cap. This allowlist is intentionally NOT `MydiaWeb.Languages.
  # all/0`'s codes: that module is presentation data ("This is presentation
  # data rather than domain data" per its own moduledoc), and whichever
  # languages happen to get a chip in some future UI must never become the
  # thing that decides what this function is willing to write to disk. A
  # bare ISO 639-1/639-3 code, optionally with a region subtag, is the
  # actual shape being trusted; anything else (a "/", a "..", a null byte,
  # an absolute path) is rejected outright rather than sanitized, because
  # stripping known-bad substrings and calling the result safe is exactly
  # the kind of denylist that the next bypass finds a gap in.
  #
  # `\A`/`\z` rather than `^`/`$`: in PCRE (what Elixir's Regex uses) a bare
  # `$` also matches just before a single trailing newline, so "en\n" would
  # otherwise pass and land in a filename with an embedded newline. Same
  # trap, same engine, already documented on `@filename_pattern` in
  # lib/mydia/streaming/session_subtitles.ex. Do not "simplify" this back
  # to `^...$`.
  @language_pattern ~r/\A[a-z]{2,3}(-[A-Z]{2})?\z/

  defp validate_language(language) when is_binary(language) do
    if Regex.match?(@language_pattern, language) do
      :ok
    else
      {:error, "That is not a valid language code"}
    end
  end

  defp validate_language(_language), do: {:error, "That is not a valid language code"}

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
  # final path itself.
  #
  # The directory mkdir_p targets is deliberately recomputed from
  # `media_file` via MediaFile.absolute_path/1, a database-backed value,
  # and NOT derived from `path` (Path.dirname(path) would have been the
  # obvious shortcut). `path` is built in destination/3 by interpolating
  # the caller-supplied `language`; validate_language/1 in upload/3 already
  # rejects anything that is not a bare language code before path is ever
  # built, but mkdir_p-ing a directory computed from that same path would
  # have been a second, independent way for a "../../etc/evil" style value
  # to escape: mkdir_p is exactly the primitive that turns a `..`-laden
  # path into a real, walkable filesystem location, since File.write/3
  # alone cannot resolve a path through directories that do not yet exist.
  # Keeping mkdir_p's target pinned to the media file's own real directory
  # means this stays safe even for some future caller of destination/3
  # that does not go through upload/3's validation.
  #
  # mkdir_p is the non-raising form: the media directory normally already
  # exists (the video file lives there), so this never actually attempts a
  # write; File.write/3 below is what surfaces a read-only mount, and it
  # returns an error tuple rather than raising.
  #
  # :exclusive closes the gap between destination/3's own File.exists?
  # check and this write: two uploads racing for the same path would both
  # pass that check, and without :exclusive the second write would silently
  # overwrite the first's bytes on disk while both still insert their own
  # database row. With it, the loser gets :eexist here instead, reported the
  # same as if destination/3 had caught it up front.
  defp write(media_file, path, content) do
    media_dir = media_file |> MediaFile.absolute_path() |> Path.dirname()

    with :ok <- File.mkdir_p(media_dir),
         :ok <- File.write(path, content, [:exclusive]) do
      :ok
    else
      {:error, reason} -> {:error, write_error_message(path, reason)}
    end
  end

  @doc false
  # Exposed (not doc'd) purely so error-message formatting for the
  # read-only-mount case (:eacces / :erofs) can be unit tested directly.
  # The behavior behind those two reasons has no automated coverage
  # otherwise: reliably producing a real permission-denied write in a test
  # depends on the test process not running as root, which is not true of
  # every environment this suite runs in (see the skipped test in
  # test/mydia/library/scanner_test.exs for the established precedent).
  @spec write_error_message(Path.t(), atom()) :: String.t()
  def write_error_message(_path, :eexist) do
    "There is already a subtitle for that language. Delete it first."
  end

  def write_error_message(path, reason) when reason in [:eacces, :erofs] do
    "Cannot write to #{Path.dirname(path)}. That library path is read-only."
  end

  def write_error_message(_path, reason) do
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
  # trigger: format is already known-good from detect_format/1, language is
  # already known-good from validate_language/1, and the two flags are
  # never user-typed strings. Anything else reaching this branch is
  # unexpected, so it gets a generic message rather than a misleading claim
  # of duplicate content. It also does NOT interpolate the changeset's own
  # errors: those are raw Ecto/database internals, already captured by the
  # Logger.warning/2 call above for whoever reads the server logs, and not
  # something to hand an operator's browser regardless of how unlikely this
  # branch is to fire.
  defp insert_error_message(changeset) do
    duplicate? =
      Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint_name) == @duplicate_content_constraint
      end)

    if duplicate? do
      "Mydia already has a subtitle with identical content for this file"
    else
      "Could not save that subtitle. Check the server logs for details."
    end
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
