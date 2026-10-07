defmodule Mydia.Settings.StorageBackends do
  @moduledoc "CRUD for storage backends, merged with env/YAML-declared ones (DB wins by name)."

  import Ecto.Query

  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Settings.RuntimeConfig, as: RC
  alias Mydia.Settings.StorageBackend

  def list_storage_backends do
    db = Repo.all(from(b in StorageBackend, order_by: b.name))
    RC.merge_with_runtime_config(db, &RC.get_runtime_storage_backends/0, :name)
  end

  def get_storage_backend_by_name(name) when is_binary(name),
    do: Enum.find(list_storage_backends(), &(&1.name == name))

  def get_storage_backend_by_name(_), do: nil

  def get_storage_backend!(id), do: Repo.get!(StorageBackend, id)

  def create_storage_backend(attrs),
    do: %StorageBackend{} |> StorageBackend.changeset(attrs) |> Repo.insert()

  def update_storage_backend(%StorageBackend{} = b, attrs),
    do: b |> StorageBackend.changeset(attrs) |> Repo.update()

  @doc """
  Deletes a backend unless a library path still points at it. Deleting an
  in-use backend would leave those libraries unreadable, and every file in
  them would look like an outage.
  """
  def delete_storage_backend(%StorageBackend{} = b) do
    case library_path_count(b.name) do
      0 ->
        # A row removed by someone else is an error tuple, not a raise.
        Repo.delete(b, stale_error_field: :base, stale_error_message: "it no longer exists")

      count ->
        {:error,
         b
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(
           :base,
           "it is still used by #{count} library path(s); remove or move them first"
         )}
    end
  end

  # substr rather than LIKE so a name containing `_` or `%` cannot over-match.
  defp library_path_count(name) do
    exact = "s3://#{name}"
    prefix = exact <> "/"
    len = String.length(prefix)

    Repo.aggregate(
      from(lp in LibraryPath,
        where: lp.path == ^exact or fragment("substr(?, 1, ?)", lp.path, ^len) == ^prefix
      ),
      :count
    )
  end

  def change_storage_backend(%StorageBackend{} = b, attrs \\ %{}),
    do: StorageBackend.changeset(b, attrs)
end
