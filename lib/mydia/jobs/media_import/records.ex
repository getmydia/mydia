defmodule Mydia.Jobs.MediaImport.Records do
  @moduledoc false

  require Logger
  alias Mydia.Library
  alias Mydia.Library.ReleaseParser
  alias Mydia.Upgrades

  @doc false
  def create_media_file_record(path, size, episode, download, library_path) do
    # Extract metadata from filename first (as fallback). Quality only —
    # no `%TargetContext{}` needed here.
    filename_metadata = ReleaseParser.parse(Path.basename(path))

    Logger.debug("Parsed filename metadata",
      path: path,
      resolution: filename_metadata.quality.resolution,
      codec: filename_metadata.quality.codec,
      audio: filename_metadata.quality.audio
    )

    # Calculate relative path from absolute path and library path
    relative_path = Path.relative_to(path, library_path.path)

    Logger.debug("Storing media file with relative path",
      absolute_path: path,
      library_path: library_path.path,
      relative_path: relative_path,
      library_path_id: library_path.id
    )

    # Tech metadata (codec/resolution/bitrate/hdr_format) is left nil at import
    # time; the row is picked up by `Mydia.Jobs.FileAnalysis` which fills it via
    # the shared `Library.apply_analysis/2` write. We still record filename-derived
    # values as the initial best guess so quality-profile selection has something
    # to work with before analysis lands.
    attrs = %{
      relative_path: relative_path,
      library_path_id: library_path.id,
      size: size,
      resolution: filename_metadata.quality.resolution,
      codec: filename_metadata.quality.codec,
      audio_codec: filename_metadata.quality.audio,
      # A filename can reveal the HDR base but never a Dolby Vision profile
      # (that needs the DOVI record from a real probe), so
      # dolby_vision_profile/dolby_vision_bl_compat_id are deliberately left
      # unset here. Mydia.Jobs.FileAnalysis fills them from ffprobe once the
      # row is picked up.
      hdr_format: filename_metadata.quality.hdr_format,
      verified_at: DateTime.utc_now(),
      metadata: %{
        imported_from_download_id: download.id,
        imported_at: DateTime.utc_now(),
        source: filename_metadata.quality.source,
        release_group: filename_metadata.release_group,
        download_client: download.download_client,
        download_client_id: download.download_client_id
      }
    }

    # Use the episode parameter if provided, otherwise fall back to download associations
    attrs =
      cond do
        episode && episode.id ->
          Map.merge(attrs, %{
            episode_id: episode.id,
            media_item_id: nil
          })

        download.episode_id ->
          Map.merge(attrs, %{
            episode_id: download.episode_id,
            media_item_id: nil
          })

        download.media_item_id ->
          Map.merge(attrs, %{
            media_item_id: download.media_item_id,
            episode_id: nil
          })

        true ->
          Logger.error("No episode_id or media_item_id available", download_id: download.id)
          attrs
      end

    # A season pack carries one target id but delivers many episodes. Each
    # episode supersedes its OWN current best file, not the download's
    # single target, which is what lets an above-cutoff episode keep its
    # file when the gate in Task 10 (UpgradeFinalize) rejects the pack's
    # version for it. A movie import is the degenerate single-file case of
    # the same rule.
    attrs =
      Map.put(
        attrs,
        :supersedes_media_file_id,
        supersede_target(download, Map.get(attrs, :media_item_id), Map.get(attrs, :episode_id))
      )

    case Library.create_media_file(attrs) do
      {:ok, media_file} ->
        Logger.info("Created media file record",
          path: path,
          id: media_file.id,
          episode_id: media_file.episode_id,
          resolution: media_file.resolution,
          codec: media_file.codec
        )

        {:ok, media_file}

      {:error, changeset} ->
        cond do
          # A concurrent import (this job racing its own retry, or two
          # workers racing the same season pack) can lose the create/1 race
          # after this process already decided the path was free: another
          # insert won and the unique index on (library_path_id,
          # relative_path) for active rows (migration 20260901234336) turns
          # the loser's insert into a changeset error instead of a second
          # row. Adopt the row that won instead of failing the import --
          # the same "someone already put this here" reuse this function
          # already does before attempting to place the file (see "Reusing
          # existing media file" above) and the `{:existing, path}` branch
          # of resolve_conflict_path/2, just caught one step later.
          duplicate_active_path_error?(changeset) ->
            adopt_duplicate_active_path(library_path.id, relative_path, path)

          has_library_type_mismatch_error?(changeset) ->
            media_type = if episode, do: "TV show", else: "movie"

            Logger.error("Library type mismatch during import",
              path: path,
              media_type: media_type,
              download_id: download.id,
              media_item_id: download.media_item_id,
              episode_id: episode && episode.id,
              errors: format_changeset_errors(changeset)
            )

            {:error, :library_type_mismatch}

          true ->
            Logger.error("Failed to create media file record",
              path: path,
              errors: inspect(changeset.errors)
            )

            {:error, :database_error}
        end
    end
  end

  # Only an upgrade-triggered download carries "upgrade_target_media_file_id"
  # in its metadata; every ordinary import falls through the `_ -> nil` clause
  # without running the lookup below, so the hot path for the common case
  # (no upgrade in play) stays a single map pattern match.
  #
  # For an upgrade import, `Upgrades.current_best_file_id/2` resolves what
  # THIS specific file (identified by its own media_item_id/episode_id, not
  # the download's) currently supersedes.
  defp supersede_target(download, media_item_id, episode_id) do
    case download.metadata do
      %{"upgrade_target_media_file_id" => target_id} when is_binary(target_id) ->
        resolve_supersede_target(target_id, media_item_id, episode_id)

      _ ->
        nil
    end
  end

  # Episodes: deliberately NO fallback to the download's single target_id. A
  # season pack shares one target across many episodes, so an episode with no
  # existing file of its own would inherit some OTHER episode's target id —
  # exactly the cross-episode mistake this per-file resolution exists to
  # avoid. `nil` correctly means "nothing to supersede for this file".
  defp resolve_supersede_target(_target_id, _media_item_id, episode_id)
       when is_binary(episode_id) do
    Upgrades.current_best_file_id(nil, episode_id)
  end

  # Movies: one target, one file, no siblings to confuse it with, so the
  # cross-episode hazard above cannot apply. Fall back to the target the sweep
  # picked when the per-file lookup comes up empty — which it does whenever the
  # quality profile stops resolving (deleted between grab and import) or the
  # old file is no longer scorable. Leaving the pointer nil there would strand
  # the upgrade: `UpgradeFinalize` only runs for a non-nil pointer, so the
  # superseded file would never be trashed, the library would keep both copies,
  # and `Health.upgrade_health/0` — which counts stale pointers — could not see
  # it. A target that has since vanished is safe: a trash lands on
  # `:orphaned` and a hard delete nilifies the FK (`on_delete: :nilify_all`),
  # both of which clear the pointer and keep the new file.
  defp resolve_supersede_target(target_id, media_item_id, nil) do
    Upgrades.current_best_file_id(media_item_id, nil) || target_id
  end

  # Matches the specific violation `guard_unique_active_path/1` in
  # MediaFile attaches to :relative_path (declared under two constraint
  # names there because ecto_sqlite3 reports a convention-derived name
  # rather than the real one for a partial index) -- never a genuine
  # validation failure, which must still surface as an error.
  defp duplicate_active_path_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {_message, opts}} ->
      field == :relative_path and Keyword.get(opts, :constraint) == :unique
    end)
  end

  # Looks up the row that won the race and adopts it. A miss here (the
  # constraint fired but no active row exists for this path) means it was
  # trashed or deleted between the insert and this read -- nothing to adopt,
  # so report the original failure and let the caller retry.
  defp adopt_duplicate_active_path(library_path_id, relative_path, path) do
    case Library.get_media_file_by_relative_path(library_path_id, relative_path) do
      nil ->
        Logger.error("Duplicate-path constraint hit but no active row found to adopt",
          path: path,
          library_path_id: library_path_id,
          relative_path: relative_path
        )

        {:error, :database_error}

      existing ->
        Logger.info("Reusing existing media file after a duplicate-path race",
          path: path,
          id: existing.id
        )

        {:ok, existing}
    end
  end

  # Checks if a changeset has a library type mismatch error
  defp has_library_type_mismatch_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {message, _opts}} ->
      (field == :media_item_id or field == :episode_id) and
        (String.contains?(message, "cannot add movies to a library") or
           String.contains?(message, "cannot add TV episodes to a library"))
    end)
  end

  # Formats changeset errors for logging
  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
      "#{field}: #{message}"
    end)
  end
end
