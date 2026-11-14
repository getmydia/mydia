defmodule Mydia.Downloads.BuiltIn.SeedingPolicy do
  @moduledoc """
  Acts on a built-in torrent that reached the operator's seeding target.

  Pausing is a one-shot action: the row is stamped with
  `"seeding_goal_reached_at"` so a torrent the operator resumes is not paused
  again. With the `:remove` action, an imported row is left to
  `Mydia.Downloads.ClientRemoval`; an unimported one is paused, since removal
  waits for the import.
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
      if action == :remove and not is_nil(row.imported_at),
        do: :left_to_removal,
        else: pause(row, now)
    else
      _ -> :noop
    end
  end

  defp pause(row, now) do
    with {:ok, adapter, config} <- Queue.resolve_adapter(row.download_client),
         :ok <- Client.pause_torrent(adapter, config, row.download_client_id),
         :ok <- MetadataKey.put(row.id, @stamp, DateTime.to_iso8601(now)) do
      :paused
    end
  end
end
