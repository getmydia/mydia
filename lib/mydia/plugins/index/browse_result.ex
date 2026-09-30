defmodule Mydia.Plugins.Index.BrowseResult do
  @moduledoc """
  The outcome of browsing every configured plugin source (R13).

  `status` distinguishes the three non-error outcomes so the store UI can say
  something explicit instead of rendering nothing:

    * `:available` - at least one listed plugin is not installed yet.
    * `:empty` - no source listed any plugin.
    * `:all_installed` - plugins were listed, but every one is installed.

  `error` is set when a source failed. It can accompany any status, because one
  failing source does not hide the entries of the sources that answered.
  """

  alias Mydia.Plugins.Index.Entry

  @type status :: :available | :empty | :all_installed

  @type t :: %__MODULE__{
          catalog: [Entry.t()],
          status: status(),
          error: String.t() | nil,
          source_count: non_neg_integer()
        }

  defstruct catalog: [], status: :empty, error: nil, source_count: 0
end
