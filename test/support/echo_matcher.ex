defmodule Mydia.Library.EchoMatcher do
  @moduledoc """
  A matcher that echoes back the path it was given.

  Deliberately stateless, so it needs no counter, no Agent, and no cross-process
  bookkeeping. `BatchMatcher` fans its work out under `Mydia.TaskSupervisor`,
  where a process dictionary or a `$callers` allowance would not reach, and a
  named Agent would collide between async tests.

  Echoing is what makes the property observable without counting: if the batch
  matcher resolves once per folder and reuses the answer, every file in a group
  comes back carrying the *same* title, the one derived from the file the group
  happened to resolve on. If it resolved per file, each result would carry its
  own basename. So the assertion is over returned values, not over call counts.
  """

  @behaviour Mydia.Library.Matcher

  @impl true
  def match_file(path, _opts) do
    {:ok,
     %{
       provider_id: "echo",
       provider_type: :tvdb,
       title: Path.basename(path),
       year: nil,
       match_confidence: 1.0
     }}
  end
end
