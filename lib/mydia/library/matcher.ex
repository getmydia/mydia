defmodule Mydia.Library.Matcher do
  @moduledoc """
  The contract for turning one file path into a provider match.

  `Mydia.Library.BatchMatcher` orchestrates matching but does not care how a
  single file is resolved, so the resolver is a parameter rather than a
  hard-wired call. `Mydia.Library.MetadataMatcher` is the production
  implementation; tests supply their own without standing up a relay.

  This follows the same shape as the project's other seams
  (`Mydia.Metadata.Provider`, `Mydia.Indexers.Adapter`): a behaviour in `lib`,
  a deterministic stub in `test/support`.
  """

  @doc """
  Resolves one file path to a provider match.

  `opts` carries `:config` and `:provider`, forwarded unchanged from the batch
  caller.
  """
  @callback match_file(path :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
