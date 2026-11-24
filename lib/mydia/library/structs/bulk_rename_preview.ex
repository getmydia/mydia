defmodule Mydia.Library.Structs.BulkRenamePreview do
  @moduledoc """
  What a library-wide rename would do, before anything moves.

  `conflicts` lists the changed previews that cannot be renamed and why:
  `:target_exists` (the proposed path is already taken) or `:duplicate_target`
  (another file in the run proposes the same path). `sample` holds up to 20
  changed, non-conflicting previews for display.
  """

  alias Mydia.Library.Structs.RenamePreview

  defstruct total: 0, changed: 0, unchanged: 0, conflicts: [], sample: []

  @type conflict_reason :: :target_exists | :duplicate_target

  @type t :: %__MODULE__{
          total: non_neg_integer(),
          changed: non_neg_integer(),
          unchanged: non_neg_integer(),
          conflicts: [{RenamePreview.t(), conflict_reason()}],
          sample: [RenamePreview.t()]
        }
end
