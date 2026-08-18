defmodule Mix.Tasks.Mydia.Reclassify do
  @shortdoc "Recomputes category for every media item without an override"

  @moduledoc """
  One-shot classification backfill.

  Category classification shipped after many libraries were already populated,
  so items added before it have no category at all. The weekly metadata refresh
  does not cover them: it only visits monitored items, and an unmonitored show
  would stay uncategorized indefinitely.

  Classification is pure over already-stored metadata and makes no provider
  calls, so this is cheap to run over the whole table.

      mix mydia.reclassify
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    {:ok, count} = Mydia.Media.reclassify_all_media_items()
    Mix.shell().info("Reclassified #{count} media items")
  end
end
