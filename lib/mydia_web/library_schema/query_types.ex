defmodule MydiaWeb.LibrarySchema.QueryTypes do
  @moduledoc """
  Root query fields for the Library API.

  Every field declares `meta action:`, which `MydiaWeb.LibrarySchema.middleware/3`
  reads at compile time.
  """

  use Absinthe.Schema.Notation

  object :library_queries do
    @desc "Quality profiles available to assign"
    field :quality_profiles, non_null(list_of(non_null(:quality_profile))) do
      meta(action: :read_library)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Reference.quality_profiles/3)
    end
  end
end
