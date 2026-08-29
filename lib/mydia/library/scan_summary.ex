defmodule Mydia.Library.ScanSummary do
  @moduledoc """
  Normalized result of scanning a single library path.

  `Mydia.Jobs.LibraryScanner`'s processor returns lists of changed files under a
  `:changes` key, alongside scan bookkeeping callers have no business reading.
  This struct is the contract it hands back instead, so a caller that only wants
  counts cannot grow a dependency on the processor's internal shape.

  `details` carries the processor's own return value unchanged, so data such as
  `new_media_files` stays reachable by the code that already relies on it.

  `auto_linked` counts files this scan linked only because the library has
  `auto_import` enabled, across both the new-file stream and the orphan
  re-enrichment branch. It is a subset of the files the scan touched, not a
  separate kind of change.
  """

  @type t :: %__MODULE__{
          new_files: non_neg_integer(),
          modified_files: non_neg_integer(),
          deleted_files: non_neg_integer(),
          auto_linked: non_neg_integer(),
          details: map()
        }

  defstruct new_files: 0, modified_files: 0, deleted_files: 0, auto_linked: 0, details: %{}
end
