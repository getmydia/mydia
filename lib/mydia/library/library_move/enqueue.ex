defmodule Mydia.Library.LibraryMove.Enqueue do
  @moduledoc """
  Validates and starts a library move: points the item at the target library
  and enqueues `Mydia.Jobs.LibraryMove`, in one transaction so a failed
  insert leaves the item where it was. Called through `Mydia.Library.LibraryMove`.
  """

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Downloads.Download
  alias Mydia.Library.LibraryMove
  alias Mydia.Library.TargetResolver
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @import_workers ["Mydia.Jobs.MediaImport", "Mydia.Jobs.MediaRematch"]
  @pending_states ["available", "scheduled", "executing", "retryable"]

  @type error ::
          :incompatible_library
          | :disabled_library
          | :already_there
          | :import_in_progress
          | :move_in_progress
          | term()

  @spec enqueue(MediaItem.t(), LibraryPath.t(), Scope.t()) ::
          {:ok, Oban.Job.t()} | {:error, error()}
  def enqueue(%MediaItem{} = item, %LibraryPath{} = target, %Scope{} = scope) do
    with :ok <- validate(item, target) do
      Repo.transaction(fn -> retarget_and_insert(item, target, scope) end)
    end
  end

  @spec enqueue_many([MediaItem.t()], LibraryPath.t(), Scope.t()) ::
          {non_neg_integer(), [{MediaItem.t(), error()}]}
  def enqueue_many(items, %LibraryPath{} = target, %Scope{} = scope) do
    {count, failures} =
      Enum.reduce(items, {0, []}, fn item, {count, failures} ->
        case enqueue(item, target, scope) do
          {:ok, _job} -> {count + 1, failures}
          {:error, reason} -> {count, [{item, reason} | failures]}
        end
      end)

    {count, Enum.reverse(failures)}
  end

  @spec actor_id(Scope.t()) :: binary() | nil
  def actor_id(%Scope{user: %{id: id}}), do: id
  def actor_id(%Scope{}), do: nil

  defp validate(item, target) do
    cond do
      target.disabled -> {:error, :disabled_library}
      not compatible?(item, target) -> {:error, :incompatible_library}
      nothing_to_move?(item, target) -> {:error, :already_there}
      import_pending?(item) -> {:error, :import_in_progress}
      true -> :ok
    end
  end

  @doc false
  def compatible?(item, target),
    do: target.type in TargetResolver.allowed_types(TargetResolver.kind_for(item))

  defp nothing_to_move?(item, target) do
    {:ok, moves} = LibraryMove.plan(item, target)
    moves == []
  end

  # JSON operators differ between SQLite and Postgres, so args are filtered
  # here rather than in the query.
  defp import_pending?(item) do
    download_ids =
      from(d in Download, where: d.media_item_id == ^item.id, select: d.id)
      |> Repo.all()
      |> MapSet.new()

    MapSet.size(download_ids) > 0 and
      from(j in Oban.Job,
        where: j.worker in @import_workers and j.state in @pending_states,
        select: j.args
      )
      |> Repo.all()
      |> Enum.any?(&MapSet.member?(download_ids, &1["download_id"]))
  end

  defp retarget_and_insert(item, target, scope) do
    actor_id = actor_id(scope)

    args = %{
      "media_item_id" => item.id,
      "target_library_path_id" => target.id,
      "actor_id" => actor_id
    }

    with {:ok, _} <- retarget(scope, item, target, actor_id),
         {:ok, %Oban.Job{conflict?: false} = job} <-
           Mydia.Jobs.insert(Mydia.Jobs.LibraryMove.new(args)) do
      job
    else
      # A move of this item is already queued; its target is in its own args.
      {:ok, %Oban.Job{conflict?: true}} -> Repo.rollback(:move_in_progress)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retarget(scope, item, target, actor_id) do
    actor = if actor_id, do: [actor_type: :user, actor_id: actor_id], else: []

    Media.update_media_item(
      scope,
      item,
      %{library_path_id: target.id},
      [reason: "Moved to another library"] ++ actor
    )
  end
end
