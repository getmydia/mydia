defmodule Mydia.Downloads.MetadataKey do
  @moduledoc """
  Sets one key in `Download.metadata` without disturbing the others.

  The read-merge-write runs in one transaction (row-locked on PostgreSQL,
  serialized writes on SQLite, as in `Mydia.Downloads.ObservedSeedTime`), and
  uses `Repo.update_all/3` so no Downloads page reload is broadcast.
  """

  import Ecto.Query, warn: false

  alias Mydia.DB
  alias Mydia.Downloads.Download
  alias Mydia.Repo

  @doc """
  Puts `key` => `value` into the download's metadata. `:ok` for a missing row.

  A database that is busy or unreachable (SQLite `BUSY`, an exhausted pool) is
  an `{:error, exception}`, not a raise: callers run inside a poll and treat a
  failed write as one to retry.
  """
  @spec put(binary(), String.t(), term()) :: :ok | {:error, term()}
  def put(download_id, key, value) do
    result =
      Repo.transaction(fn ->
        case download_id |> locked_row() |> Repo.one() do
          nil ->
            :ok

          %Download{id: id, metadata: metadata} ->
            merged = Map.put(metadata || %{}, key, value)
            Repo.update_all(where(Download, [d], d.id == ^id), set: [metadata: merged])
            :ok
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [Exqlite.Error, Postgrex.Error, DBConnection.ConnectionError] -> {:error, error}
  end

  defp locked_row(id) do
    query = where(Download, [d], d.id == ^id)
    if DB.postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end
end
