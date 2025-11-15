defmodule Mydia.Library.Structs.GroupedFile do
  @moduledoc """
  Represents a file in the import grouping UI.

  This struct provides compile-time safety for file grouping data,
  used in both movie and ungrouped file lists.

  ## Fields

  - `:file` - The file information (map or struct)
  - `:match_result` - The metadata match result (can be nil for ungrouped files)
  - `:import_status` - The current import status (atom)
  - `:index` - The position index in the original list
  """

  alias Mydia.Library.Structs.MatchResult

  @enforce_keys [:file, :import_status, :index]
  defstruct [:file, :match_result, :import_status, :index]

  @type t :: %__MODULE__{
          file: map(),
          match_result: MatchResult.t() | nil,
          import_status: atom(),
          index: integer()
        }

  @doc """
  Creates a new GroupedFile struct.

  ## Examples

      iex> new(file: %{path: "/movies/movie.mkv"}, match_result: nil, import_status: :pending, index: 0)
      %GroupedFile{file: %{path: "/movies/movie.mkv"}, match_result: nil, import_status: :pending, index: 0}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
