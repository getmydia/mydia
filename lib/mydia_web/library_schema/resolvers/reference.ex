defmodule MydiaWeb.LibrarySchema.Resolvers.Reference do
  @moduledoc """
  Resolves the queries a caller needs before it can name anything: which quality
  profiles and library paths exist.

  `LibraryPath.type` is an Ecto.Enum over a closed value set, so it maps onto a
  GraphQL enum directly.
  """

  alias Mydia.Settings

  @spec quality_profiles(any(), map(), Absinthe.Resolution.t()) :: {:ok, [map()]}
  def quality_profiles(_parent, _args, _info) do
    profiles = Settings.list_quality_profiles()

    {:ok, Enum.map(profiles, &%{id: &1.id, name: &1.name})}
  end

  @spec library_paths(any(), map(), Absinthe.Resolution.t()) :: {:ok, [map()]}
  def library_paths(_parent, _args, _info) do
    paths = Settings.list_library_paths()

    {:ok, Enum.map(paths, &%{id: &1.id, path: &1.path, type: &1.type})}
  end
end
