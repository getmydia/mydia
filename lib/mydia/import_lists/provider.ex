defmodule Mydia.ImportLists.Provider do
  @moduledoc """
  Behaviour for import list providers.

  This module defines the interface for fetching items from various import list sources.
  Each provider implementation handles a specific source type (TMDB, etc.).
  """

  alias Mydia.ImportLists.ImportList

  @type item :: %{
          tmdb_id: integer(),
          title: String.t(),
          year: integer() | nil,
          poster_path: String.t() | nil,
          media_type: String.t()
        }

  @doc """
  Fetches items from the import list source.

  Returns `{:ok, items}` with a list of items, or `{:error, reason}` if fetching fails.
  """
  @callback fetch_items(import_list :: ImportList.t()) ::
              {:ok, [item()]} | {:error, term()}

  @doc """
  Returns true if this provider can handle the given import list type.
  """
  @callback supports?(type :: String.t()) :: boolean()
end
