defmodule Mydia.Plugins.Index.CatalogItem do
  @moduledoc """
  One store entry as the store modal shows it: the entry plus how it relates to
  what is installed.

    * `:not_installed` - no plugin with this slug is installed.
    * `:bundled` - the slug is a bundled plugin; the store cannot replace it.
    * `:installed` - installed from an index at this exact version.
    * `:update` - installed from an index at an older version.
    * `:replace` - sideloaded, or installed at a version newer than the store's.
    * `:other_source` - the slug is installed from another source; installing
      replaces it and moves its updates to this source.

  `installed_version` is the installed plugin's version, `nil` for
  `:not_installed`. `installed_from` names the installed plugin's source and is
  set only for `:other_source`.
  """

  alias Mydia.Plugins.Index.Entry

  @type state :: :not_installed | :bundled | :installed | :update | :replace | :other_source

  @type t :: %__MODULE__{
          entry: Entry.t(),
          state: state(),
          installed_version: String.t() | nil,
          installed_from: String.t() | nil
        }

  @enforce_keys [:entry, :state]
  defstruct [:entry, :state, :installed_version, :installed_from]
end
