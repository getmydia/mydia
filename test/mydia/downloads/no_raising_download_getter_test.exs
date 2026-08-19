defmodule Mydia.Downloads.NoRaisingDownloadGetterTest do
  @moduledoc """
  Application code must load downloads with `Downloads.get_download/2`, never the
  raising `get_download!/2`.

  A download row is deleted routinely and from several directions: an operator
  deleting from the UI, an import that finishes and cleans up, `Queue`/`Grabber`
  stale-record cleanup, and `DownloadMonitor`'s own reject path. Anything holding
  an id across a gap — an Oban job between enqueue and run, a poll between its
  database snapshot and its per-row handler, a LiveView between render and click —
  can find the row gone. That is an ordinary race, not an exceptional condition.

  Issue #281 is what happens when the only getter raises: `Ecto.NoResultsError`
  crashed `DownloadMonitor.perform/1` 356 times across two instances in five
  weeks, and because the crash aborted the whole job, every handler queued behind
  the failing one silently stopped running for that poll.

  The deeper problem was that nil-safety was opt-in. Six call sites hand-rolled
  `rescue Ecto.NoResultsError` around the bang getter and five forgot, with
  nothing in the signature to say which was which. This guard removes the choice:
  `get_download/2` returns `nil` and the compiler-visible return type forces the
  caller to say what that means.

  `get_download!/2` deliberately survives for tests, where a row that vanished
  unexpectedly *should* fail loudly. It just may not be called from `lib/`.
  """
  use ExUnit.Case, async: true

  # The definition, its delegate, and its `@spec` — the only places the name may
  # legitimately appear under lib/. Everything else is a call site.
  @definition_sites [
    "lib/mydia/downloads.ex",
    "lib/mydia/downloads/history.ex"
  ]

  test "no application code under lib/ calls the raising download getter" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 in @definition_sites))
      |> Enum.flat_map(&raising_calls/1)

    assert offenders == [], """
    These call sites use the raising `get_download!/2` (issue #281):

    #{Enum.map_join(offenders, "\n", fn {file, line, text} -> "  #{file}:#{line}  #{text}" end)}

    Use `Mydia.Downloads.get_download/2` and handle `nil` explicitly. A download
    row can be deleted between the read that produced its id and the read that
    acts on it; that is expected, and raising there takes down the job or the
    LiveView around it.
    """
  end

  test "the definition sites expose a non-bang getter alongside the bang one" do
    # Guards the guard: if `get_download/2` were ever removed, every call site
    # above would have to go back to the bang version and the test above would
    # still pass on an empty codebase-wide search.
    for file <- @definition_sites do
      source = File.read!(file)

      assert source =~ "get_download(",
             "#{file} must keep a non-bang `get_download/2` for lib/ to call"
    end
  end

  # Strips comments before matching so the prose in this fix's own explanatory
  # comments does not trip the guard. Matches a qualified call
  # (`Downloads.get_download!(`) rather than the bare name, which would also hit
  # `def`/`defdelegate`/`@spec`.
  defp raising_calls(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _no} -> String.trim_leading(line) |> String.starts_with?("#") end)
    |> Enum.filter(fn {line, _no} -> line =~ ~r/\.get_download!\(/ end)
    |> Enum.map(fn {line, no} -> {file, no, String.trim(line)} end)
  end
end
