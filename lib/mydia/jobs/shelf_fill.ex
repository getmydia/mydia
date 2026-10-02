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

  require Logger

  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.Shelves
  alias Mydia.Plugins.Shelves.Declared

  @crash_message_max 300

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"shelf_id" => shelf_id}}) do
    with %Shelf{} = shelf <- Shelves.get_shelf(shelf_id),
         %Declared{} = declared <- Shelves.get_declared(shelf.plugin_slug, shelf.shelf_key),
         true <- Shelves.stale?(shelf, DateTime.utc_now()) do
      run(shelf, declared)
    end

    :ok
  end

  @doc """
  Runs one fill, turning an exception into a recorded failure so the shelf backs
  off instead of being refilled on the next visit. `fill` is the function that
  does the work, `&Mydia.Plugins.Shelves.fill/2` unless a test passes its own.
  """
  @spec run(Shelf.t(), Declared.t(), (Shelf.t(), Declared.t() -> term())) :: :ok
  def run(%Shelf{} = shelf, %Declared{} = declared, fill \\ &Shelves.fill/2) do
    fill.(shelf, declared)
    :ok
  rescue
    exception ->
      message = exception |> Exception.message() |> String.slice(0, @crash_message_max)
      Logger.warning("ShelfFill crashed", shelf_id: shelf.id, error: message)
      record_crash(shelf, declared, message)
  end

  # The fill may have written its claim before it raised, so read the row again
  # for an up to date failure_count. A row deleted mid-fill has nothing to record.
  defp record_crash(shelf, declared, message) do
    case Shelves.get_shelf(shelf.id) do
      %Shelf{} = current -> Shelves.record_crash(current, declared, "fill crashed: " <> message)
      nil -> :ok
    end

    :ok
  rescue
    _exception -> :ok
  end

  # The guest call itself is bounded by the page timeout, and each verification
  # fetch has its own deadline; this is the backstop. A job killed here leaves
  # the claim `Shelves.fill/3` wrote, so the shelf is not refilled at once.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(180)
end
