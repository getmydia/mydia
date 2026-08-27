defmodule Mydia.Subtitles.Sidecars do
  @moduledoc """
  Adopts subtitle files that already sit next to a media file, and deletes
  `subtitles` rows whose file has since disappeared.

  `Mydia.Library.Scanner` only indexes video extensions, and the `subtitles`
  table is written by exactly one function, `Mydia.Subtitles.Downloader.download/3`.
  Anyone arriving from Plex or Jellyfin with `Movie.en.srt` beside `Movie.mkv`
  therefore gets nothing until `reconcile/1` or `reconcile_all/1` runs against
  that directory. The same pass deletes a row once its file is gone from disk,
  taking its stored offset correction with it. Reconciliation only ever reads
  the filesystem and writes the database; it never creates, modifies, or
  deletes a file.
  """

  import Ecto.Query
  require Logger

  alias Mydia.Library
  alias Mydia.Library.FileRanking
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Subtitles.Format
  alias Mydia.Subtitles.Subtitle
  alias Mydia.Subtitles.TrackSettings

  @extensions ~w(.srt .ass .ssa .vtt)

  @empty_tally %{adopted: 0, reaped: 0, skipped: 0, errors: []}

  # A fixed table, never `String.to_atom/1` on a filename fragment. Keys are
  # matched downcased. ISO 639-2 codes and English names both map onto the
  # 639-1 code the rest of the system uses.
  @languages %{
    "en" => "en",
    "eng" => "en",
    "english" => "en",
    "es" => "es",
    "spa" => "es",
    "esp" => "es",
    "spanish" => "es",
    "fr" => "fr",
    "fra" => "fr",
    "fre" => "fr",
    "french" => "fr",
    "de" => "de",
    "deu" => "de",
    "ger" => "de",
    "german" => "de",
    "it" => "it",
    "ita" => "it",
    "italian" => "it",
    "pt" => "pt",
    "por" => "pt",
    "portuguese" => "pt",
    "nl" => "nl",
    "nld" => "nl",
    "dut" => "nl",
    "dutch" => "nl",
    "sv" => "sv",
    "swe" => "sv",
    "swedish" => "sv",
    "da" => "da",
    "dan" => "da",
    "danish" => "da",
    "no" => "no",
    "nor" => "no",
    "norwegian" => "no",
    "fi" => "fi",
    "fin" => "fi",
    "finnish" => "fi",
    "pl" => "pl",
    "pol" => "pl",
    "polish" => "pl",
    "ru" => "ru",
    "rus" => "ru",
    "russian" => "ru",
    "ja" => "ja",
    "jpn" => "ja",
    "japanese" => "ja",
    "ko" => "ko",
    "kor" => "ko",
    "korean" => "ko",
    "zh" => "zh",
    "chi" => "zh",
    "zho" => "zh",
    "chinese" => "zh",
    "ar" => "ar",
    "ara" => "ar",
    "arabic" => "ar",
    "he" => "he",
    "heb" => "he",
    "hebrew" => "he",
    "hi" => "hi",
    "hin" => "hi",
    "hindi" => "hi",
    "tr" => "tr",
    "tur" => "tr",
    "turkish" => "tr",
    "cs" => "cs",
    "ces" => "cs",
    "cze" => "cs",
    "czech" => "cs",
    "el" => "el",
    "ell" => "el",
    "gre" => "el",
    "greek" => "el",
    "hu" => "hu",
    "hun" => "hu",
    "hungarian" => "hu",
    "ro" => "ro",
    "ron" => "ro",
    "rum" => "ro",
    "romanian" => "ro",
    "th" => "th",
    "tha" => "th",
    "thai" => "th",
    "uk" => "uk",
    "ukr" => "uk",
    "ukrainian" => "uk",
    "vi" => "vi",
    "vie" => "vi",
    "vietnamese" => "vi"
  }

  @forced_tags ~w(forced)
  @hearing_impaired_tags ~w(sdh cc)

  @doc "The sidecar file extensions this module adopts."
  @spec extensions() :: [String.t()]
  def extensions, do: @extensions

  @doc """
  Reads language and flags out of a sidecar filename.

  `media_basename` is the media file's name with its own extension removed,
  and may itself contain dots (`Some.Movie.2019.1080p`). Everything between
  it and the subtitle extension is a dot-separated tag list, matched against
  `basename` case-insensitively.

  An unrecognized tag is ignored rather than treated as a language, so
  `Movie.HDR.en.srt` still resolves to `en`. A file with no recognizable
  language tag resolves to `"und"`.

  Note the collision between the ISO 639-1 code for Hindi and the common
  shorthand for "hearing impaired", both spelled `hi`. It reads as a
  language, because that tag position means language and Hindi subtitles
  are real; `sdh` and `cc` remain unambiguous. A file wanting both says
  `Movie.hi.sdh.srt`.
  """
  @spec parse_filename(String.t(), String.t()) :: %{
          language: String.t(),
          forced: boolean(),
          hearing_impaired: boolean()
        }
  def parse_filename(basename, media_basename) do
    tags =
      basename
      |> Path.rootname()
      |> String.downcase()
      |> String.replace_prefix(String.downcase(media_basename), "")
      |> String.split(".", trim: true)

    %{
      language: Enum.find_value(tags, "und", &Map.get(@languages, &1)),
      forced: Enum.any?(tags, &(&1 in @forced_tags)),
      hearing_impaired: Enum.any?(tags, &(&1 in @hearing_impaired_tags))
    }
  end

  @type tally :: %{
          adopted: non_neg_integer(),
          reaped: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [{Path.t(), term()}]
        }

  @doc """
  Brings the `subtitles` rows for one media file into agreement with the
  sidecar files actually sitting beside it.

  Three cases:

    * on disk with no row: adopted, with `origin: "sidecar"`
    * on disk with a row: left alone, which is what stops this from clobbering
      what `Mydia.Subtitles.Downloader` wrote (those are sidecars in the same
      directory following the same naming)
    * a row whose file is gone: deleted, along with its stored offset

  A sidecar whose name is a prefix match for more than one media file in the
  directory (a multi-version folder such as `Movie.mkv` beside
  `Movie.Extended.mkv`, where a sidecar named `Movie.Extended.en.srt` starts
  with both basenames) is adopted by whichever sibling has the longest
  matching basename, never by more than one. A trashed sibling still counts
  as a candidate for this: trashing `Movie.Extended.mkv` does not move its
  sidecar, so `Movie.Extended.en.srt` must keep losing the match against
  `Movie.mkv` even though the longer-basename file is no longer active (it
  simply then has no active owner and stays unadopted, rather than getting
  attached to the wrong media file).

  Two siblings that reduce to the exact same basename (same title, different
  container, such as `Movie.mkv` beside `Movie.mp4`) cannot be told apart by
  name at all. In that case the sidecar is adopted by whichever one
  `Mydia.Library.FileRanking.best/1` would pick as the primary file; the
  other adopts nothing. That is a deliberate, accepted gap rather than a
  second row pointing at the same file.

  Siblings are read from the database (`Mydia.Library.list_media_files/1`,
  scoped to this file's `library_path_id` and directory, trashed rows
  included), not from any argument list, so a single-file rescan sees the
  same candidate set a full `reconcile_all/1` pass would.

  Returns `{:error, reason}` without touching anything when the directory
  cannot be listed. That branch is load-bearing: see `reconcile_dir/5`.
  """
  @spec reconcile(MediaFile.t()) :: {:ok, tally()} | {:error, term()}
  def reconcile(media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        {:error, :no_absolute_path}

      absolute_path ->
        dir = Path.dirname(absolute_path)
        media_basename = basename_for(absolute_path)

        case File.ls(dir) do
          {:ok, entries} ->
            siblings = siblings_in_dir(media_file.library_path_id, dir)
            {:ok, reconcile_dir(media_file, dir, media_basename, siblings, entries)}

          {:error, reason} ->
            log_and_error(dir, reason)
        end
    end
  end

  @doc """
  Runs `reconcile/1` over many media files, listing each directory once.

  A season folder holding ten episodes would otherwise be listed ten times. An
  error on one directory is accumulated rather than aborting the pass.

  The sibling lookup that decides ownership (see `reconcile/1`) is likewise
  run once per distinct `{directory, library_path_id}` pair within a
  directory group rather than once per file, since the flat, single-library
  layout common in self-hosted setups would otherwise issue one
  `Mydia.Library.list_media_files/1` call per file, each scanning every
  active file in that library path. Scoping the cached lookup by
  `library_path_id` as well as directory, instead of by directory alone,
  keeps this exactly equivalent to calling `reconcile/1` on each file one at
  a time even in the unusual case of two library paths overlapping the same
  physical directory.
  """
  @spec reconcile_all([MediaFile.t()]) :: tally()
  def reconcile_all(media_files) do
    media_files
    |> Enum.group_by(&dir_for/1)
    |> Enum.reduce(@empty_tally, fn
      {nil, _files}, tally ->
        tally

      {dir, files}, tally ->
        case File.ls(dir) do
          {:ok, entries} ->
            siblings_by_library_path =
              files
              |> Enum.map(& &1.library_path_id)
              |> Enum.uniq()
              |> Map.new(&{&1, siblings_in_dir(&1, dir)})

            Enum.reduce(files, tally, fn media_file, acc ->
              basename = media_file |> MediaFile.absolute_path() |> basename_for()
              siblings = Map.fetch!(siblings_by_library_path, media_file.library_path_id)
              merge_tally(acc, reconcile_dir(media_file, dir, basename, siblings, entries))
            end)

          {:error, reason} ->
            {:error, _} = log_and_error(dir, reason)
            %{tally | errors: [{dir, reason} | tally.errors]}
        end
    end)
  end

  @doc """
  Resolves which media file would adopt a sidecar named `filename` sitting
  beside `media_file`, using the exact ownership rule `reconcile/1` uses:
  longest matching basename among siblings in the same directory and
  library path, ties broken by `Mydia.Library.FileRanking.best/1`.
  `filename` is a bare filename (`Path.basename/1`'s shape), not a full path.

  Returns `nil` when `media_file` has no resolvable location, in which case
  there is no directory to look siblings up in. Otherwise always returns a
  media file: `media_file` itself is always among its own siblings, so its
  own basename is always at least one candidate match.

  Exposed for `Mydia.Subtitles.Uploader`, which calls this before writing an
  uploaded file. Two sibling media files that reduce to the exact same
  basename (`Movie.mkv` beside `Movie.mp4`) cannot be told apart by name, so
  `reconcile/1` attributes their shared sidecar to whichever one wins here,
  never to both. Writing a row for the file that loses this tie-break sets
  up the exact dual-adoption bug this module exists to prevent: reconcile
  would see the same path as unclaimed from the winner's point of view and
  adopt it a second time, leaving two rows pointing at one file.
  """
  @spec owning_media_file_for(MediaFile.t(), String.t()) :: MediaFile.t() | nil
  def owning_media_file_for(media_file, filename) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        nil

      absolute_path ->
        dir = Path.dirname(absolute_path)
        siblings = siblings_in_dir(media_file.library_path_id, dir)
        owning_media_file(filename, siblings)
    end
  end

  ## Private

  defp dir_for(media_file) do
    case MediaFile.absolute_path(media_file) do
      nil -> nil
      path -> Path.dirname(path)
    end
  end

  defp basename_for(path), do: path |> Path.basename() |> Path.rootname()

  # Every media file sharing this directory under `library_path_id`, trashed
  # rows included. `reconcile/1` and `reconcile_all/1` both call this (with
  # the same `library_path_id` for the same file, whichever entry point is
  # used) and nothing else to decide who a sidecar belongs to, which is what
  # keeps the two in agreement: the candidate set a single-file "Rescan
  # subtitles" button sees is exactly the set a full pass would compute for
  # that same file, because it comes from the database rather than from
  # whatever subset of files the caller happened to pass in.
  #
  # Trashed rows are included on purpose. `Library.list_media_files/1`
  # excludes them by default, which caused two separate corruption paths
  # before this was fixed:
  #
  #   * reconciling a trashed media file itself would drop its own basename
  #     from the candidate list, so none of its sidecars would match, so
  #     every existing row for it would look orphaned and get reaped, even
  #     with the file still on disk;
  #   * a sidecar belonging to a trashed sibling (trashing a media file moves
  #     the video but nothing moves its sidecar) would lose its rightful,
  #     longer-basename owner and fall through to an active neighbour with a
  #     shorter, merely-prefix-matching basename instead.
  #
  # Trashed or not, every row is a real, still-existing media file as far as
  # a sidecar's ownership is concerned.
  defp siblings_in_dir(library_path_id, dir) do
    [library_path_id: library_path_id, preload: [:library_path], include_trashed: true]
    |> Library.list_media_files()
    |> Enum.filter(&(dir_for(&1) == dir))
  end

  # Everything below this point runs only after `File.ls/1` has returned
  # `{:ok, entries}`. That is deliberate and it is the most important line in
  # this module: a directory that fails to list is indistinguishable from an
  # empty one at the call site, and the difference is whether every subtitle
  # row for this file gets deleted. An empty scan trashing a whole library
  # has happened here before.
  defp reconcile_dir(media_file, dir, media_basename, siblings, entries) do
    on_disk =
      entries
      |> Enum.filter(&sidecar_for?(&1, media_file, siblings))
      |> Enum.map(&Path.join(dir, &1))
      |> MapSet.new()

    existing = list_subtitle_rows(media_file.id)
    known_paths = existing |> Enum.map(& &1.file_path) |> MapSet.new()

    reaped =
      existing
      |> Enum.reject(&MapSet.member?(on_disk, &1.file_path))
      |> Enum.count(fn subtitle ->
        TrackSettings.delete_for_track(media_file.id, subtitle.id)
        match?({:ok, _}, Repo.delete(subtitle))
      end)

    {adopted, skipped} =
      on_disk
      |> Enum.reject(&MapSet.member?(known_paths, &1))
      |> Enum.reduce({0, 0}, fn path, {adopted, skipped} ->
        case adopt(media_file, path, media_basename) do
          :ok -> {adopted + 1, skipped}
          :skip -> {adopted, skipped + 1}
        end
      end)

    %{adopted: adopted, reaped: reaped, skipped: skipped, errors: []}
  end

  # A sidecar belongs to whichever sibling's basename is the longest prefix
  # match, never to more than one. Required deviation from a bare
  # `String.starts_with?/2` check against a single basename: a multi-version
  # folder such as `Movie.mkv` beside `Movie.Extended.mkv` means a sidecar
  # named `Movie.Extended.en.srt` starts with both basenames, and adopting it
  # onto both would point two subtitle rows at one file. Deleting either row
  # through `Mydia.Subtitles.delete_subtitle/1` then removes a file that still
  # legitimately belongs to the other media file.
  defp sidecar_for?(entry, media_file, siblings) do
    sidecar_extension?(entry) and
      case owning_media_file(entry, siblings) do
        nil -> false
        owner -> owner.id == media_file.id
      end
  end

  defp sidecar_extension?(entry), do: String.downcase(Path.extname(entry)) in @extensions

  # Two prefixes of the same fixed string that share the longest matching
  # length must be the same string, so a length tie here always means two
  # sibling media files reduced to the exact same basename (same title,
  # different container, e.g. `Movie.mkv` beside `Movie.mp4`), not two
  # merely-similar names. Name matching alone cannot break that tie, so it
  # is resolved by `Mydia.Library.FileRanking.best/1`, the same ranking this
  # codebase already uses to pick the primary file for a media item
  # (`MydiaWeb.Api.Player.V1.SubtitleController`). Every other sibling
  # tied at that length adopts nothing; the accepted cost is that a
  # secondary file shows no subtitle track for that sidecar even though the
  # file sits right next to it.
  defp owning_media_file(entry, siblings) do
    matches =
      siblings
      |> Enum.map(&{&1, &1 |> MediaFile.absolute_path() |> basename_for()})
      |> Enum.filter(fn {_media_file, basename} -> String.starts_with?(entry, basename) end)

    case matches do
      [] ->
        nil

      matches ->
        max_length =
          matches |> Enum.map(fn {_media_file, b} -> String.length(b) end) |> Enum.max()

        matches
        |> Enum.filter(fn {_media_file, b} -> String.length(b) == max_length end)
        |> Enum.map(fn {media_file, _b} -> media_file end)
        |> FileRanking.best()
    end
  end

  defp list_subtitle_rows(media_file_id) do
    Subtitle
    |> where([s], s.media_file_id == ^media_file_id)
    |> Repo.all()
  end

  defp adopt(media_file, path, media_basename) do
    with {:ok, content} <- File.read(path),
         {:ok, format} <- Format.detect(content) do
      parsed = parse_filename(Path.basename(path), media_basename)

      attrs = %{
        media_file_id: media_file.id,
        language: parsed.language,
        provider: "sidecar",
        origin: "sidecar",
        forced: parsed.forced,
        hearing_impaired: parsed.hearing_impaired,
        subtitle_hash: hash(content),
        file_path: path,
        format: format
      }

      %Subtitle{}
      |> Subtitle.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, _subtitle} ->
          :ok

        {:error, changeset} ->
          # The common cause is the (media_file_id, subtitle_hash) unique index:
          # two byte-identical sidecars for one media file, such as
          # `Movie.en.srt` beside `Movie.eng.srt`. One row is the right answer;
          # this logs so the skip does not read as a bug later.
          Logger.info("Sidecar not adopted",
            path: path,
            errors: inspect(changeset.errors)
          )

          :skip
      end
    else
      {:error, reason} ->
        Logger.info("Sidecar unreadable or unrecognized", path: path, reason: inspect(reason))
        :skip
    end
  end

  defp hash(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp merge_tally(a, b) do
    %{
      adopted: a.adopted + b.adopted,
      reaped: a.reaped + b.reaped,
      skipped: a.skipped + b.skipped,
      errors: a.errors ++ b.errors
    }
  end

  defp log_and_error(dir, reason) do
    Logger.warning("Sidecar reconciliation skipped, directory unreadable",
      directory: dir,
      reason: inspect(reason)
    )

    {:error, reason}
  end
end
