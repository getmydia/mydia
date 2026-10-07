defmodule Mydia.Settings.StorageBackends do
  @moduledoc "CRUD for storage backends, merged with env/YAML-declared ones (DB wins by name)."

  import Ecto.Query

  alias Mydia.Repo
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

  def delete_storage_backend(%StorageBackend{} = b), do: Repo.delete(b)

  def change_storage_backend(%StorageBackend{} = b, attrs \\ %{}),
    do: StorageBackend.changeset(b, attrs)
end
