defmodule Mydia.Indexers.Cardigann.ParseStats do
  @moduledoc """
  What happened to the rows of one Cardigann response: how many the row selector
  matched, how many `andmatch` filtered out on purpose, and how many were
  dropped because a required field (title, download) came back empty.

  A response with matched rows and zero results used to look exactly like an
  empty search. `dropped` is how the health check and the live sweep tell them
  apart.
  """

  @type t :: %__MODULE__{
          matched: non_neg_integer(),
          filtered: non_neg_integer(),
          dropped: non_neg_integer(),
          first_missing: String.t() | nil
        }

  defstruct matched: 0, filtered: 0, dropped: 0, first_missing: nil
end
