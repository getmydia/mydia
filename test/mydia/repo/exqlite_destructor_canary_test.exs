defmodule Mydia.Repo.ExqliteDestructorCanaryTest do
  # Canary for patches/exqlite/. The Docker image builds Exqlite with a patch
  # that stops a dropped statement from stalling the VM while its connection
  # busy-waits. Dev and CI use the unpatched upstream NIF, so this test watches
  # upstream: it passes while the stall still exists there.
  #
  # When it fails, an Exqlite release has fixed the destructor. Retire the
  # patch: delete patches/exqlite/, the Exqlite steps in the Dockerfile, and
  # this test.
  use ExUnit.Case, async: true

  @probe Path.expand("../../../patches/exqlite/destructor_probe.exs", __DIR__)
  @busy_timeout_ms 1_000

  test "upstream Exqlite still stalls the VM when a statement is dropped mid busy wait" do
    stall_ms = measure_in_single_scheduler_vm(@busy_timeout_ms)

    assert stall_ms >= div(@busy_timeout_ms, 2), """
    Dropping a statement stalled the VM for only #{stall_ms}ms while its \
    connection busy-waited for #{@busy_timeout_ms}ms. Upstream Exqlite no longer \
    blocks there, so patches/exqlite/ is obsolete: delete it, its Dockerfile \
    steps and this test.
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
