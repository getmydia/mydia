defmodule Mydia.IndexerMock.ParkedSearch do
  @moduledoc """
  State shared between a search handler parked by
  `Mydia.IndexerMock.park_prowlarr_search/1` and
  `Mydia.IndexerMock.release_parked_searches/0`.

  `released` is sticky, so a request that reaches the handler after the
  release answers at once. `parked` holds the handler pids waiting for
  `:release`.
  """
  defstruct released: false, parked: []

  @type t :: %__MODULE__{released: boolean(), parked: [pid()]}
end
