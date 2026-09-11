defmodule MydiaWeb.LibrarySchema.ReferenceTypes do
  @moduledoc """
  Types the Library API refers to but does not own.

  Every one is an object rather than a scalar name or id, so a field can be added
  to it later without breaking a client that already selects it.
  """

  use Absinthe.Schema.Notation

  @desc "A quality profile"
  object :quality_profile do
    field :id, non_null(:id)
    field :name, non_null(:string)
  end

  @desc "A library path Mydia scans"
  object :library_path do
    field :id, non_null(:id)
    field :path, non_null(:string)
    field :type, non_null(:library_path_type)
  end

  @desc "Pagination info"
  object :page_info do
    field :has_next_page, non_null(:boolean)
    field :end_cursor, :string
  end
end
