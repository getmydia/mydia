defmodule Mydia.Streaming.SessionSubtitles do
  @moduledoc """
  Subtitle files belonging to one HLS streaming session.

  A Chromecast fetches a sidecar subtitle over plain HTTP, and on the p2p
  bridge there is no plain HTTP to fetch from: `Mydia.P2p` speaks pairing,
  GraphQL and HLS, and nothing else. But both serving paths already hand out
  any path-validated file inside a session's temp directory, so a WebVTT file
  written there is reachable on both routes with no new endpoint, no protocol
  change, and no separate authentication: session auth already covers it.

  Materialization is lazy. A Chromecast fetches a track's body when the track
  is *activated*, and Mydia defaults casts to subtitles off, so a cast where
  nobody turns subtitles on does no work here at all.

  The lock below serialises extraction within one session; it is keyed by
  `temp_dir`, so it does not stop two different sessions racing on the same
  media file. Cross-session deduplication is `Mydia.Subtitles.Delivery`'s own
  job: `content/3` keeps an on-disk cache keyed by media file id, track id, an
  mtime/size stamp and format, so a second session's ffmpeg run is the
  exception rather than the rule, not a structural guarantee. This module only
  copies those bytes into the session directory, which is a few KB of write.

  Image-based tracks (PGS, VobSub) never materialize. Enforcing that here
  rather than in the player means no client can offer one by mistake.
  """

  alias Mydia.Library
  alias Mydia.Streaming.SessionFiles
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Extractor

  require Logger

  @format "vtt"

  @lock Mydia.Streaming.SubtitleLock

  # An ffprobe stream index, or a sidecar UUID. Anchored at both ends so a
  # name like "subs_3.vtt.exe" or "subs_../x.vtt" cannot match. `\z` rather
  # than `$`: in PCRE (what Elixir's Regex uses) a bare `$` also matches just
  # before a single trailing newline, so "subs_3.vtt\n" would otherwise pass.
  @filename_pattern ~r/^subs_([0-9]+|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.vtt\z/

  @doc "The session-relative filename for `track_id`."
  @spec filename(integer() | String.t()) :: String.t()
  def filename(track_id), do: "subs_#{track_id}.vtt"

  @doc """
  The track id inside a subtitle filename, or `:error` when `name` is not one.

  An integer name comes back as an integer and a UUID as a string, because
  that is the split `Mydia.Subtitles.Delivery.content/3` dispatches on.
  """
  @spec track_id_from_filename(String.t()) :: {:ok, integer() | String.t()} | :error
  def track_id_from_filename(name) do
    case Regex.run(@filename_pattern, name) do
      [_, id] -> {:ok, cast_track_id(id)}
      nil -> :error
    end
  end

  @doc """
  Makes sure the subtitle file `name` exists in this session, extracting it if
  it does not.

  Returns `:not_subtitle` when `name` is not a subtitle filename, which is the
  signal for the caller to fall through to its ordinary segment handling.
  """
  @spec ensure(map(), String.t()) :: {:ok, String.t()} | {:error, term()} | :not_subtitle
  def ensure(%{temp_dir: temp_dir, media_file_id: media_file_id}, name) do
    with {:ok, track_id} <- track_id_from_filename(name),
         {:ok, path} <- SessionFiles.safe_path(temp_dir, name) do
      if File.exists?(path) do
        {:ok, path}
      else
        # Two receivers, or a receiver and a retry, can ask for the same track
        # at once. Without the lock both run ffmpeg and both write the same
        # file. `:wait` rather than `:skip`: the second caller wants the file,
        # not a "busy" it would have to translate into a 404.
        case Mydia.Plugins.SingleFlight.run(
               lock_slug(temp_dir, name),
               :wait,
               fn ->
                 # Re-check inside the lock: the process we waited behind may
                 # be the one that just wrote this file.
                 if File.exists?(path) do
                   {:ok, path}
                 else
                   materialize(media_file_id, track_id, path)
                 end
               end,
               @lock
             ) do
          {:busy} -> {:error, :busy}
          result -> result
        end
      end
    else
      # Both a non-subtitle name and a traversal attempt dressed as one are
      # "not a subtitle request". The caller's own path validation is what
      # rejects the traversal; returning :error here would turn a bad name
      # into a 500 instead of a 404.
      :error -> :not_subtitle
      # Unreachable while @filename_pattern holds: every name it admits
      # contains only digits or hex-and-hyphens between "subs_" and ".vtt",
      # so it can never carry "/" or "..". Kept anyway as defence-in-depth,
      # so the regex is not the single point of failure if it is ever loosened.
      {:error, :path_traversal} -> :not_subtitle
    end
  end

  defp lock_slug(temp_dir, name), do: "session_subtitle:#{temp_dir}:#{name}"

  defp materialize(media_file_id, track_id, path) do
    media_file = Library.get_media_file!(media_file_id, preload: [:library_path])

    with :ok <- check_deliverable(media_file, track_id),
         {:ok, body} <- Delivery.content(media_file, track_id, @format),
         :ok <- atomic_write(path, body) do
      {:ok, path}
    else
      {:error, reason} = error ->
        Logger.warning("Session subtitle unavailable",
          media_file_id: media_file_id,
          track_id: track_id,
          reason: inspect(reason)
        )

        error
    end
  rescue
    Ecto.NoResultsError -> {:error, :media_file_not_found}
    Ecto.Query.CastError -> {:error, :media_file_not_found}
  end

  # `ensure/2`'s fast path (`File.exists?(path)`, checked before the lock is
  # even acquired) trusts a directory entry at `path` as proof of a complete
  # file. Writing straight to `path` would break that: the entry appears the
  # moment the write starts, so a reader outside the lock could observe a
  # truncated body mid-write, and a crash or disk-full error mid-write would
  # leave a broken file behind that the fast path never revalidates. Writing
  # to a unique temp name in the same directory and renaming into place
  # avoids both — a rename within one filesystem is atomic, so `path` either
  # does not exist yet or already holds the complete body. Either failure
  # step cleans up the temp file so it never lingers as an orphan.
  defp atomic_write(path, body) do
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, body),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      error ->
        File.rm(tmp_path)
        error
    end
  end

  defp check_deliverable(media_file, track_id) do
    media_file
    |> Extractor.list_subtitle_tracks()
    |> Enum.find(&(to_string(&1.track_id) == to_string(track_id)))
    |> case do
      nil -> {:error, :subtitle_not_found}
      %{deliverable: false} -> {:error, :image_subtitle}
      _track -> :ok
    end
  end

  defp cast_track_id(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end
end
