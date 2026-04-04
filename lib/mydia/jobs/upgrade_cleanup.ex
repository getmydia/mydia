defmodule Mydia.Jobs.UpgradeCleanup do
  @moduledoc """
  Handles old file cleanup after a quality upgrade download is imported.

  Enqueued by MediaImport when a download with `download_reason: "upgrade"`
  completes successfully. Queries old media files for the movie, validates
  ownership, and applies the configured file policy (replace or keep).

  This is a separate job from MediaImport to:
  - Keep MediaImport focused on import logic
  - Make cleanup independently retryable
  - Ensure the new file is fully available before acting on old files
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger

  import Ecto.Query, warn: false

  alias Mydia.{Repo, Library}
  alias Mydia.Library.MediaFile

  @doc """
  Enqueues an upgrade cleanup job for a completed upgrade import.

  ## Parameters
    - `media_item_id` - The media item that was upgraded
    - `new_media_file_ids` - List of newly imported media file IDs to preserve
  """
  def enqueue(media_item_id, new_media_file_ids) when is_list(new_media_file_ids) do
    %{
      "media_item_id" => media_item_id,
      "new_media_file_ids" => new_media_file_ids
    }
    |> new()
    |> Oban.insert()
  end

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "media_item_id" => media_item_id,
          "new_media_file_ids" => new_media_file_ids
        }
      }) do
    policy = get_file_policy()

    Logger.info("Running upgrade cleanup",
      media_item_id: media_item_id,
      new_file_ids: new_media_file_ids,
      policy: policy
    )

    case policy do
      "keep" ->
        Logger.info("Upgrade file policy is 'keep', skipping old file cleanup",
          media_item_id: media_item_id
        )

        :ok

      "replace" ->
        trash_old_files(media_item_id, new_media_file_ids)
    end
  end

  defp trash_old_files(media_item_id, new_media_file_ids) do
    # Query old files: same media_item, not trashed, not the newly imported files
    old_files =
      from(mf in MediaFile,
        where: mf.media_item_id == ^media_item_id,
        where: mf.id not in ^new_media_file_ids,
        where: is_nil(mf.trashed_at)
      )
      |> Repo.all()

    if old_files == [] do
      Logger.info("No old files to clean up", media_item_id: media_item_id)
      :ok
    else
      Logger.info("Trashing #{length(old_files)} old files after upgrade",
        media_item_id: media_item_id,
        old_file_ids: Enum.map(old_files, & &1.id)
      )

      Enum.each(old_files, fn file ->
        case Library.trash_media_file(file) do
          {:ok, _trashed} ->
            Logger.info("Trashed old media file",
              media_file_id: file.id,
              media_item_id: media_item_id
            )

          {:error, reason} ->
            Logger.error("Failed to trash old media file",
              media_file_id: file.id,
              media_item_id: media_item_id,
              reason: inspect(reason)
            )
        end
      end)

      :ok
    end
  end

  defp get_file_policy do
    Mydia.Settings.get_config([:downloads, :upgrade_file_policy], "replace")
  end
end
