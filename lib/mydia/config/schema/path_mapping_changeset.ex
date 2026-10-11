defmodule Mydia.Config.Schema.PathMappingChangeset do
  @moduledoc """
  Changeset for one `path_mappings` entry of `Mydia.Config.Schema`: a remote
  prefix (as a download client reports it) mapped to a local prefix (as Mydia
  sees it).

  Both prefixes are normalized, must be absolute and free of `..` segments, the
  remote prefix must be at least two segments deep so a mapping can never cover
  a whole filesystem root, and the two prefixes must differ.
  """

  import Ecto.Changeset

  alias Mydia.Settings.PathMappingConfig

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:remote_prefix, :local_prefix])
    |> update_change(:remote_prefix, &PathMappingConfig.normalize_prefix/1)
    |> update_change(:local_prefix, &PathMappingConfig.normalize_prefix/1)
    |> validate_required([:remote_prefix, :local_prefix])
    |> validate_absolute(:remote_prefix)
    |> validate_absolute(:local_prefix)
    |> validate_no_traversal(:remote_prefix)
    |> validate_no_traversal(:local_prefix)
    |> validate_remote_prefix_specific()
    |> validate_distinct_prefixes()
  end

  defp validate_absolute(changeset, field) do
    case get_field(changeset, field) do
      "/" <> _ -> changeset
      nil -> changeset
      _ -> add_error(changeset, field, "must be an absolute path (start with /)")
    end
  end

  defp validate_no_traversal(changeset, field) do
    case get_field(changeset, field) do
      value when is_binary(value) ->
        if ".." in Path.split(value) do
          add_error(changeset, field, "must not contain '..' segments")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_remote_prefix_specific(changeset) do
    case get_field(changeset, :remote_prefix) do
      value when is_binary(value) ->
        if length(Path.split(value)) < 3 do
          add_error(
            changeset,
            :remote_prefix,
            "must be at least two path segments deep (e.g. /downloads/complete)"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_distinct_prefixes(changeset) do
    remote = get_field(changeset, :remote_prefix)
    local = get_field(changeset, :local_prefix)

    if not is_nil(remote) and remote == local do
      add_error(changeset, :local_prefix, "must differ from the remote prefix")
    else
      changeset
    end
  end
end
