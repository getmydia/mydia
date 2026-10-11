defmodule Mydia.Downloads.Queue.Rematch do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.History
  alias Mydia.Downloads.Structs.ExternalTorrent
  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem

  # --- Issues Tab Functions ---

  def manually_match_download(%Download{} = download, media_item_id, episode_id \\ nil) do
    save_path = get_in(download.metadata || %{}, ["save_path"])

    # Keep match_status until import succeeds (import job clears it)
    attrs = %{
      media_item_id: media_item_id,
      episode_id: episode_id
    }

    case History.update_download(download, attrs) do
      {:ok, updated} ->
        job_result =
          %{
            "download_id" => updated.id,
            "save_path" => save_path,
            "cleanup_client" => true,
            "use_hardlinks" => true
          }
          |> Mydia.Jobs.MediaImport.new()
          |> Mydia.Jobs.insert()

        case job_result do
          {:ok, _job} -> {:ok, updated}
          {:error, _changeset} = error -> error
        end

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Creates a tracked download for a foreign client torrent and queues its import.

  Foreign torrents are derived and have no database row, so matching one is a
  create rather than an update. The row is written with `match_status: nil`,
  which is exactly what a normally-grabbed download looks like, so everything
  downstream treats it as ordinary work instead of a special case.

  Returns `{:error, :already_tracked}` when the unique
  `(download_client, download_client_id)` pair is taken, which is what a second
  browser tab adopting the same torrent hits.
  """
  @spec adopt_external_torrent(ExternalTorrent.t(), binary(), binary() | nil) ::
          {:ok, Download.t()} | {:error, :already_tracked} | {:error, Ecto.Changeset.t()}
  def adopt_external_torrent(%ExternalTorrent{} = torrent, media_item_id, episode_id \\ nil) do
    attrs = %{
      indexer: "manual",
      title: torrent.title,
      download_url: nil,
      download_client: torrent.client_name,
      download_client_id: torrent.client_id,
      media_item_id: media_item_id,
      episode_id: episode_id,
      metadata: %{
        size: torrent.size,
        save_path: torrent.save_path,
        matched_from_client: true
      }
    }

    with {:ok, download} <- create_adopted_download(attrs),
         {:ok, _job} <- enqueue_adopted_import(download, torrent.save_path) do
      {:ok, download}
    end
  end

  defp create_adopted_download(attrs) do
    case History.create_download(attrs) do
      {:ok, download} ->
        {:ok, download}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Keyword.has_key?(errors, :download_client) do
          {:error, :already_tracked}
        else
          error
        end
    end
  end

  defp enqueue_adopted_import(download, save_path) do
    %{
      "download_id" => download.id,
      "save_path" => save_path,
      "cleanup_client" => true,
      "use_hardlinks" => true
    }
    |> Mydia.Jobs.MediaImport.new()
    |> Mydia.Jobs.insert()
  end

  def resolve_file_mappings(%Download{} = download, mappings) when is_list(mappings) do
    # Build target_files for the MediaImport job (mappings always use string keys)
    target_files =
      Enum.map(mappings, fn mapping ->
        %{
          "path" => mapping["path"],
          "episode_id" => mapping["episode_id"]
        }
      end)

    # Don't clear match_status or unresolved_files metadata here — the import job
    # clears them on success. This preserves data for retry if import fails.
    case %{
           "download_id" => download.id,
           "target_files" => target_files,
           "use_hardlinks" => true
         }
         |> Mydia.Jobs.MediaImport.new()
         |> Mydia.Jobs.insert() do
      {:ok, _job} -> {:ok, download}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Re-matches an already-imported download to a corrected movie or episode.

  Validates lifecycle, scope, and library-type compatibility before any mutation,
  then enqueues `Mydia.Jobs.MediaRematch` to move + relink the file. Single-target
  only: a download whose provenance resolves to multiple imported files (a pack)
  is refused.

  Returns:
    * `{:ok, :enqueued}` — a re-match job was scheduled
    * `{:ok, :unchanged}` — the target already matches; nothing to do
    * `{:error, :not_imported}` — not imported yet (use in-flight correction)
    * `{:error, :not_single_target}` — partial_pack / unresolved_files / unmatched
    * `{:error, :multiple_files}` — pack: per-file re-match not supported
    * `{:error, :no_imported_file}` — could not locate the imported file
    * `{:error, :no_library_path}` — no monitored, compatible destination library
    * `{:error, :library_type_mismatch}` — target type incompatible with library
  """
  def rematch_imported_download(%Download{} = download, media_item_id, episode_id \\ nil) do
    cond do
      is_nil(download.imported_at) ->
        {:error, :not_imported}

      not is_nil(download.match_status) ->
        {:error, :not_single_target}

      download.media_item_id == media_item_id and download.episode_id == episode_id ->
        {:ok, :unchanged}

      true ->
        do_rematch(download, media_item_id, episode_id)
    end
  end

  defp do_rematch(download, media_item_id, episode_id) do
    media_item = media_item_id && Repo.get(MediaItem, media_item_id)
    episode = episode_id && Repo.get(Episode, episode_id)

    with {:ok, _file} <- locate_single_imported_file(download),
         {:ok, library_path} <- resolve_rematch_destination(media_item, episode),
         :ok <- ensure_type_compatible(library_path, media_item, episode_id) do
      case History.update_download(download, %{
             media_item_id: media_item_id,
             episode_id: episode_id
           }) do
        {:ok, updated} ->
          case %{"download_id" => updated.id}
               |> Mydia.Jobs.MediaRematch.new()
               |> Mydia.Jobs.insert() do
            {:ok, _job} -> {:ok, :enqueued}
            {:error, _changeset} = error -> error
          end

        {:error, _changeset} = error ->
          error
      end
    end
  end

  defp locate_single_imported_file(download) do
    case Mydia.Library.list_media_files_for_download(download) do
      [%MediaFile{} = file] -> {:ok, file}
      [] -> {:error, :no_imported_file}
      _multiple -> {:error, :multiple_files}
    end
  end

  defp resolve_rematch_destination(media_item, episode) do
    # Resolves against the NEW target: the download row still holds the old one
    # here, so no download is passed and step 1 is skipped by design.
    _ = episode

    case media_item && Mydia.Library.TargetResolver.resolve(media_item) do
      {:ok, library_path, _reason} -> {:ok, library_path}
      _ -> {:error, :no_library_path}
    end
  end

  defp ensure_type_compatible(library_path, media_item, episode_id) do
    media_item_type = media_item && media_item.type

    if MediaFile.library_type_compatible?(
         library_path.type,
         media_item_type,
         not is_nil(episode_id)
       ) do
      :ok
    else
      {:error, :library_type_mismatch}
    end
  end
end
