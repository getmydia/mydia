defmodule Mydia.Downloads.BuiltIn.SeedingPolicy do
  @moduledoc """
  Acts on a built-in torrent that reached the operator's seeding target and
  met its tracker's terms (`Mydia.Downloads.SeedingGoal.goal_met?/4`, through
  `SeedingGoal.for_download/2`). A private torrent whose tracker rules are
  unknown never meets them, so it is never paused here.

  Pausing is a one-shot action: the row is stamped with
  `"seeding_goal_reached_at"` so a torrent the operator resumes is not paused
  again. With the `:remove` action, an imported row is left to
  `Mydia.Downloads.ClientRemoval`; an unimported one is paused, since removal
  waits for the import, and so is one with unresolved files, which removal
  skips.
  """

  alias Mydia.Downloads.{BuiltIn, Client, MetadataKey, Queue, SeedingGoal}
  alias Mydia.Downloads.Structs.EnrichedDownload

  @stamp "seeding_goal_reached_at"

  @spec apply(EnrichedDownload.t(), DateTime.t()) ::
          :paused | :left_to_removal | :noop | {:error, term()}
  def apply(%EnrichedDownload{} = row, now) do
    with %{action: action} <- BuiltIn.seeding_target(),
         true <- SeedingGoal.currently_seeding?(row),
         nil <- Map.get(row.metadata || %{}, @stamp),
         %SeedingGoal{met?: true} <- SeedingGoal.for_download(row, now: now) do
      if action == :remove and removable?(row),
        do: :left_to_removal,
        else: pause(row, now)
    else
      _ -> :noop
    end
  end

  # What `ClientRemoval` will pick up: imported, and not held back by files
  # it could not match (those it skips, so they would seed on forever).
  defp removable?(row),
    do: not is_nil(row.imported_at) and row.match_status != "unresolved_files"

  defp pause(row, now) do
    with {:ok, adapter, config} <- Queue.resolve_adapter(row.download_client),
         :ok <- Client.pause_torrent(adapter, config, row.download_client_id),
         :ok <- MetadataKey.put(row.id, @stamp, DateTime.to_iso8601(now)) do
      :paused
    end
  end
end
