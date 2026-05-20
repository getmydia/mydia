defmodule Mydia.Streaming.Torrent.Promotion do
  @moduledoc """
  Handles promoting torrent streaming files to the permanent library.
  """
  require Logger
  alias Mydia.Repo
  alias Mydia.Streaming.Torrent.SessionSchema
  alias Mydia.Library.MediaFile
  alias Mydia.Library.FileOrganizer
  alias Mydia.Settings.LibraryPath

  @doc """
  Promotes a torrent session's file to the library.
  """
  def promote(session_id) do
    case Repo.get(SessionSchema, session_id) |> Repo.preload([:media_item, :episode]) do
      nil -> {:error, :not_found}
      session -> do_promote(session)
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
           {:ok, source_path} when is_binary(source_path) <- {:ok, session.staging_path} do
        # 2. Create destination directory
        File.mkdir_p!(dest_folder)

        # 3. Move file
        filename = Path.basename(source_path)
        dest_path = Path.join(dest_folder, filename)

        Logger.info("Promoting torrent file: #{source_path} -> #{dest_path}")

        case move_file(source_path, dest_path) do
          :ok ->
            # 4. Create MediaFile record (with compensation on failure)
            create_media_file_with_compensation(session, library_path, source_path, dest_path)

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

  defp move_file(source_path, dest_path) do
    case File.rename(source_path, dest_path) do
      :ok ->
        :ok

      {:error, :exdev} ->
        # Cross-device move: copy then delete
        with :ok <- File.cp(source_path, dest_path),
             :ok <- File.rm(source_path) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_media_file_with_compensation(session, library_path, source_path, dest_path) do
    case create_media_file(session, library_path, dest_path) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        # DB failed after the filesystem move — attempt to move the file back
        Logger.error(
          "MediaFile DB insert failed after promoting #{dest_path}: #{inspect(reason)}. " <>
            "Attempting to move file back to staging."
        )

        case File.rename(dest_path, source_path) do
          :ok ->
            Logger.info("Successfully rolled back file to staging: #{source_path}")

          {:error, rollback_reason} ->
            Logger.warning(
              "Rollback failed — file left at #{dest_path} without a DB record: #{inspect(rollback_reason)}"
            )
        end

        {:error, reason}
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

    %MediaFile{}
    |> MediaFile.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, media_file} ->
        # 5. Mark session as completed
        session
        |> SessionSchema.changeset(%{state: :completed})
        |> Repo.update()

        {:ok, media_file}

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
