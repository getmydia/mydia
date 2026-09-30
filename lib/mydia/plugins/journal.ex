defmodule Mydia.Plugins.Journal do
  @moduledoc """
  The record of every write a plugin page made for a user, and undo.

  Entries hold host-resolved arguments and the inverse `Mydia.Plugins.PageWrites`
  computed, never page content. A batch is every write from one page request or
  one confirmation, and undoing a batch reverts it newest first.
  """

  import Ecto.Query

  alias Mydia.Accounts.User
  alias Mydia.Plugins.JournalEntry
  alias Mydia.Plugins.PageWrites
  alias Mydia.Repo

  @spec record(
          String.t(),
          binary(),
          String.t(),
          map(),
          map(),
          PageWrites.inverse(),
          String.t(),
          String.t()
        ) :: {:ok, JournalEntry.t() | nil} | {:error, Ecto.Changeset.t()}
  def record(_slug, _user_id, _op, _args, _result, :noop, _description, _batch_id),
    do: {:ok, nil}

  def record(slug, user_id, op, args, result, inverse, description, batch_id) do
    {inverse_map, status} =
      case inverse do
        :irreversible -> {nil, "irreversible"}
        map when is_map(map) -> {map, "applied"}
      end

    %JournalEntry{}
    |> JournalEntry.changeset(%{
      plugin_slug: slug,
      user_id: user_id,
      op: op,
      surface: PageWrites.surface(op),
      args: args,
      result: result,
      inverse: inverse_map,
      description: description,
      batch_id: batch_id,
      status: status
    })
    |> Repo.insert()
  end

  @spec list(String.t(), binary(), pos_integer()) :: [JournalEntry.t()]
  def list(slug, user_id, limit \\ 100) do
    JournalEntry
    |> where([e], e.plugin_slug == ^slug and e.user_id == ^user_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec undo_entry(User.t(), binary()) ::
          {:ok, JournalEntry.t()}
          | {:error, :not_found | :conflict | :irreversible | :already_undone | term()}
  def undo_entry(%User{} = user, entry_id) do
    case Repo.get_by(JournalEntry, id: entry_id, user_id: user.id) do
      nil -> {:error, :not_found}
      entry -> undo(user, entry)
    end
  end

  @spec undo_batch(User.t(), String.t(), String.t()) :: {:ok, [JournalEntry.t()]}
  def undo_batch(%User{} = user, slug, batch_id) do
    entries =
      JournalEntry
      |> where([e], e.plugin_slug == ^slug and e.user_id == ^user.id and e.batch_id == ^batch_id)
      |> where([e], e.status == "applied")
      |> order_by([e], desc: e.inserted_at)
      |> Repo.all()

    {:ok,
     Enum.map(entries, fn entry ->
       case undo(user, entry) do
         {:ok, updated} -> updated
         {:error, _} -> Repo.get!(JournalEntry, entry.id)
       end
     end)}
  end

  defp undo(_user, %JournalEntry{status: "undone"}), do: {:error, :already_undone}
  defp undo(_user, %JournalEntry{status: "irreversible"}), do: {:error, :irreversible}
  defp undo(_user, %JournalEntry{status: "conflict"}), do: {:error, :conflict}

  # The entry is claimed first with a status-conditional update (applied ->
  # undone), so a second undo of the same entry finds nothing to claim and the
  # inverse never runs twice. It is not one transaction with the inverse: the
  # inverse may run its own transaction and roll it back on a conflict, which
  # would poison an enclosing one. A claim whose inverse fails is released.
  defp undo(user, %JournalEntry{} = entry) do
    origin = "plugin:#{entry.plugin_slug}"

    with :ok <- claim(entry) do
      result =
        try do
          PageWrites.undo(entry.op, entry.args, entry.result, entry.inverse, user, origin)
        rescue
          exception ->
            set_status(entry, "applied")
            reraise exception, __STACKTRACE__
        end

      case result do
        :ok ->
          {:ok, Repo.get!(JournalEntry, entry.id)}

        {:error, :conflict} ->
          set_status(entry, "conflict")
          {:error, :conflict}

        {:error, :irreversible} ->
          set_status(entry, "irreversible")
          {:error, :irreversible}

        {:error, other} ->
          set_status(entry, "applied")
          {:error, other}
      end
    end
  end

  defp claim(entry) do
    query = from(e in JournalEntry, where: e.id == ^entry.id and e.status == "applied")

    case Repo.update_all(query, set: [status: "undone"]) do
      {1, _} -> :ok
      {0, _} -> {:error, :already_undone}
    end
  end

  defp set_status(entry, status) do
    Repo.update_all(from(e in JournalEntry, where: e.id == ^entry.id), set: [status: status])
  end
end
