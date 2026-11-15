defmodule Mydia.Repo.ExqlitePatchTest do
  # Regression guard for the Exqlite statement-destructor stall fixed upstream
  # in Exqlite 0.42.0 (elixir-sqlite/exqlite#361). Unpatched, dropping a
  # statement while its connection busy-waits blocks the connection mutex and
  # stalls the VM scheduler for the full busy_timeout, which CI saw as
  # `database is locked` flakes (.github/ci-flakes.md, CandidatePromotionTest).
  #
  # This fails if a regression reintroduces the destructor stall.
  use ExUnit.Case, async: true

  @probe Path.expand("../../support/exqlite_destructor_probe.exs", __DIR__)
  @busy_timeout_ms 1_000

  test "the Exqlite NIF in use does not stall the VM when a statement is dropped mid busy wait" do
    stall_ms = measure_in_single_scheduler_vm(@busy_timeout_ms)

    assert stall_ms < div(@busy_timeout_ms, 4), """
    Dropping a statement stalled the VM for #{stall_ms}ms while its connection \
    busy-waited for #{@busy_timeout_ms}ms. Upstream Exqlite 0.42.0 (#361) \
    fixed this destructor stall; check if a regression was introduced in Exqlite.
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
