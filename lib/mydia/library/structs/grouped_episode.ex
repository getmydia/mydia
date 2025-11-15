defmodule Mydia.Library.Structs.GroupedEpisode do
  @moduledoc """
  Represents an episode in a season grouping within the import UI.

  This struct provides compile-time safety for episode grouping data,
  used when organizing TV show episodes by season.

  ## Fields

  - `:file` - The file information (map or struct)
  - `:match_result` - The metadata match result
  - `:index` - The position index in the original list
  """

  alias Mydia.Library.Structs.MatchResult

  @enforce_keys [:file, :match_result, :index]
  defstruct [:file, :match_result, :import_status, :index]

  @type t :: %__MODULE__{
          file: map(),
          match_result: MatchResult.t(),
          import_status: atom() | nil,
          index: integer()
        }

  @doc """
  Creates a new GroupedEpisode struct.

  ## Examples

      iex> new(file: %{path: "/tv/show.s01e01.mkv"}, match_result: %{...}, index: 0)
      %GroupedEpisode{file: %{path: "/tv/show.s01e01.mkv"}, ...}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
