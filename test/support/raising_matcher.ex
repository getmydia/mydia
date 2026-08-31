defmodule Mydia.Library.RaisingMatcher do
  @moduledoc """
  A matcher that raises the moment it is called.

  Used to prove a code path never reaches matching at all -- unlike
  `Mydia.Library.FailingMatcher` or `Mydia.Library.CrashingMatcher`, which
  return a deterministic error tuple (a legitimate outcome of *having run*),
  this one turns any invocation into a loud, unambiguous test failure. See
  `Mydia.Jobs.LibraryScanner.discover_unknown_paths/3`: with a library
  path's `auto_import` set to false, the scanner must never construct a
  matcher call for an unrecognized path, so a test can pass this module as
  `:matcher` and assert the scan still succeeds.
  """

  @behaviour Mydia.Library.Matcher

  @impl true
  def match_file(path, _opts) do
    raise "RaisingMatcher.match_file/2 was called for #{path} -- matching must not run here"
  end
end
