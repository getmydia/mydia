defmodule Mydia.Library.ScanSummary do
  @moduledoc """
  Normalized result of scanning a single library path.

  `Mydia.Jobs.LibraryScanner` dispatches scanning by library type, and the
  per-type processors return different shapes. The video processor returns
  lists of changed files under a `:changes` key, while the music, books and
  adult processors return integer counts directly. This struct is the single
  contract at that dispatch boundary, so callers cannot accidentally depend on
  one branch's shape.

  `details` carries the originating processor's own return value unchanged, so
  branch-specific data such as `new_media_files` stays reachable by the code
  that already relies on it.
  """

  @type t :: %__MODULE__{
          new_files: non_neg_integer(),
          modified_files: non_neg_integer(),
          deleted_files: non_neg_integer(),
          details: map()
        }

  defstruct new_files: 0, modified_files: 0, deleted_files: 0, details: %{}
end
