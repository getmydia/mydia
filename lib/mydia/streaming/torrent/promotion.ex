defmodule Mydia.Streaming.Torrent.Promotion do
  @moduledoc """
  Handles promoting torrent streaming files to the permanent library.
  """
  require Logger
  alias Mydia.Repo
  alias Mydia.Library
  alias Mydia.Streaming.Torrent.SessionSchema
  alias Mydia.Library.FileOrganizer
  alias Mydia.Settings.LibraryPath

  # Promotion is only safe once the engine has actually finished downloading.
  # Promoting at 80% download but 90% playback would move a truncated file
  # into the library.
  @download_complete_threshold 1.0

  @doc """
  Promotes a torrent session's file to the library.

  Refuses to promote unless the session is in a streamable state AND the
  engine has downloaded the full file. Sessions that have crossed the
  playback threshold but not the download threshold remain in :watching
  and will be retried on the next progress event.
  """
  def promote(session_id) do
    case Repo.get(SessionSchema, session_id) |> Repo.preload([:media_item, :episode]) do
      nil ->
        {:error, :not_found}

      session ->
        cond do
          session.state in [:completed, :failed, :cancelled] ->
            {:error, :not_promotable}

          (session.download_progress || 0.0) < @download_complete_threshold ->
            Logger.info(
              "Skipping promotion for session #{session_id}: download_progress=" <>
                "#{inspect(session.download_progress)} (need >= #{@download_complete_threshold})"
            )

            {:ok, :download_incomplete}

          true ->
            do_promote(session)
        end
    end
  end

  defp do_promote(session) do
    # 1. Determine destination library path
    media_item =
      session.media_item ||
        (session.episode && Repo.preload(session.episode, :media_item).media_item)

    if is_nil(media_item) do
      {:error, :no_media_item}
    else
      with {:ok, library_path} <- find_best_library_path(media_item),
           {:ok, dest_folder} <- {:ok, FileOrganizer.destination_path(media_item, library_path)},
           {:ok, source_path} when is_binary(source_path) <- {:ok, session.staging_path},
           :ok <- ensure_directory(dest_folder) do
        # 3. Move file
        filename = Path.basename(source_path)
        dest_path = Path.join(dest_folder, filename)

        Logger.info("Promoting torrent file: #{source_path} -> #{dest_path}")

        case move_file(source_path, dest_path) do
          {:ok, :renamed} ->
            create_media_file_with_compensation(
              session,
              library_path,
              source_path,
              dest_path,
              :renamed
            )

          {:ok, :copied} ->
            create_media_file_with_compensation(
              session,
              library_path,
              source_path,
              dest_path,
              :copied
            )

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:ok, nil} ->
          {:error, :staging_path_missing}

        error ->
          error
      end
    end
  end

  defp ensure_directory(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  # Public for testing: tests pass an injected `:file_module` to simulate
  # cross-device moves (rename returning :exdev) without touching a real
  # cross-mount filesystem.
  @doc false
  def move_file(source_path, dest_path, opts \\ []) do
    file_module = Keyword.get(opts, :file_module, File)

    case file_module.rename(source_path, dest_path) do
      :ok ->
        {:ok, :renamed}

      {:error, :exdev} ->
        # Cross-device move: copy then delete. If the copy succeeds but rm
        # fails, the library file is already in place — treat the rm
        # failure as non-fatal (warn and continue).
        case file_module.cp(source_path, dest_path) do
          :ok ->
            case file_module.rm(source_path) do
              :ok ->
                {:ok, :copied}

              {:error, rm_reason} ->
                Logger.warning(
                  "Promotion: cross-device move succeeded for #{dest_path} but staging " <>
                    "removal failed (#{inspect(rm_reason)}). Leaving staging file as orphan."
                )

                {:ok, :copied}
            end

          {:error, reason} ->
            {:error, {:cp_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_media_file_with_compensation(
         session,
         library_path,
         source_path,
         dest_path,
         move_kind
       ) do
    case create_media_file(session, library_path, dest_path) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        # DB failed after the filesystem move — attempt to roll back the file
        # to staging. The rollback must mirror the forward move (rename for
        # same-device, copy+rm for cross-device); a plain `rename` across
        # mounts fails with :exdev and leaves the file orphaned.
        Logger.error(
          "MediaFile DB insert failed after promoting #{dest_path}: #{inspect(reason)}. " <>
            "Attempting to move file back to staging."
        )

        case rollback_move(dest_path, source_path, move_kind) do
          :ok ->
            Logger.info("Successfully rolled back file to staging: #{source_path}")

          {:error, rollback_reason} ->
            Logger.warning(
              "Rollback failed for #{dest_path}: #{inspect(rollback_reason)}. " <>
                "File left at destination without a DB record."
            )
        end

        {:error, reason}
    end
  end

  defp rollback_move(dest_path, source_path, :renamed) do
    case File.rename(dest_path, source_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_move(dest_path, source_path, :copied) do
    with :ok <- File.cp(dest_path, source_path),
         :ok <- File.rm(dest_path) do
      :ok
    end
  end

  defp find_best_library_path(media_item) do
    type = if media_item.type == "movie", do: :movies, else: :series

    LibraryPath
    |> Repo.get_by(type: type, disabled: false)
    |> case do
      nil ->
        # Fallback to any mixed library
        LibraryPath
        |> Repo.get_by(type: :mixed, disabled: false)
        |> case do
          nil -> {:error, :no_library_path_found}
          path -> {:ok, path}
        end

      path ->
        {:ok, path}
    end
  end

  defp create_media_file(session, library_path, dest_path) do
    relative_path = Path.relative_to(dest_path, library_path.path)

    attrs = %{
      media_item_id: session.media_item_id,
      episode_id: session.episode_id,
      library_path_id: library_path.id,
      relative_path: relative_path,
      size: session.total_bytes,
      verified_at: DateTime.utc_now()
    }

    case Library.create_media_file(attrs) do
      {:ok, media_file} ->
        # Mark session as completed. The file is already in the library, so
        # don't fail the whole promotion if this state update fails — just
        # log so the admin dashboard inconsistency can be debugged later.
        case Repo.update(SessionSchema.changeset(session, %{state: :completed})) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            Logger.error(
              "Failed to mark session #{session.id} as :completed after promotion: " <>
                inspect(changeset)
            )
        end

        {:ok, media_file}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
