defmodule Mydia.Jobs.ShelfFill do
  @moduledoc """
  Fills one plugin shelf for one user.

  Enqueued by `Mydia.Plugins.Shelves.refresh_stale/1` when a page shows a stale
  shelf. Unique per shelf, so repeated visits while a fill is queued or running
  add nothing. One attempt only: a failed fill is recorded on the shelf with
  its own backoff, and retrying here would spend a second model run for the
  same failure.

  Runs on its own queue. A fill can take two minutes, and the `plugins` queue
  has a single slot that carries the every-minute scheduler tick.
  """

  use Oban.Worker,
    queue: :shelves,
    max_attempts: 1,
    unique: [period: 300, keys: [:shelf_id]]

  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.Shelves
  alias Mydia.Plugins.Shelves.Declared

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"shelf_id" => shelf_id}}) do
    with %Shelf{} = shelf <- Shelves.get_shelf(shelf_id),
         %Declared{} = declared <- Shelves.get_declared(shelf.plugin_slug, shelf.shelf_key),
         true <- Shelves.stale?(shelf, DateTime.utc_now()) do
      Shelves.fill(shelf, declared)
    end

    :ok
  end

  # The guest call itself is bounded by the page timeout; this covers the
  # verification fetches after it.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(180)
end
