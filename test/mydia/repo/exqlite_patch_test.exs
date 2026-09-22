defmodule Mydia.Repo.ExqlitePatchTest do
  # Guard for patches/exqlite/. Every `mix deps.get` patches Exqlite so that
  # dropping a statement cannot stall the VM while its connection busy-waits.
  # Unpatched, that stall made the lock holder in any SQLite write contention
  # wait out the full busy_timeout, which CI saw as `database is locked`
  # flakes (.github/ci-flakes.md, CandidatePromotionTest).
  #
  # This fails if the NIF under test is not the patched one: the patch did not
  # apply, or a build from before it survived. `mix deps.get` then
  # `mix deps.compile exqlite --force` rebuilds it.
  use ExUnit.Case, async: true

  @probe Path.expand("../../../patches/exqlite/destructor_probe.exs", __DIR__)
  @busy_timeout_ms 1_000

  test "the Exqlite NIF in use does not stall the VM when a statement is dropped mid busy wait" do
    stall_ms = measure_in_single_scheduler_vm(@busy_timeout_ms)

    assert stall_ms < div(@busy_timeout_ms, 4), """
    Dropping a statement stalled the VM for #{stall_ms}ms while its connection \
    busy-waited for #{@busy_timeout_ms}ms, so this is the unpatched Exqlite NIF. \
    Run `mix deps.get` (which applies patches/exqlite/) and \
    `mix deps.compile exqlite --force`.
    """
  end

  # The stall only reproduces deterministically with one normal scheduler, and
  # the test VM has many, so the probe runs in a child VM.
  defp measure_in_single_scheduler_vm(busy_timeout_ms) do
    elixir = System.find_executable("elixir") || flunk("elixir is not on PATH")

    {output, 0} =
      System.cmd(elixir, [
        "--erl",
        "+S 1:1",
        "-pa",
        Application.app_dir(:exqlite, "ebin"),
        "-r",
        @probe,
        "-e",
        "IO.puts(ExqliteDestructorProbe.measure(#{busy_timeout_ms}))"
      ])

    output |> String.split() |> List.last() |> String.to_integer()
  end
end
