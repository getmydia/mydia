defmodule Mydia.BoundedCommandTest do
  use ExUnit.Case, async: true

  alias Mydia.BoundedCommand

  describe "run/3" do
    test "returns the child's combined output on a normal exit" do
      assert {:ok, output} = BoundedCommand.run("echo", ["hello"], 5_000)
      assert String.trim(output) == "hello"
    end

    test "reports the exit code and output on a non-zero exit" do
      assert {:error, {:exit, 7, _output}} = BoundedCommand.run("sh", ["-c", "exit 7"], 5_000)
    end

    test "reports :not_found for a missing executable" do
      assert {:error, :not_found} =
               BoundedCommand.run("definitely-not-a-real-mydia-binary", [], 5_000)
    end

    test "a wedged command times out instead of blocking the caller" do
      started_at = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = BoundedCommand.run("sleep", ["5"], 100)

      elapsed = System.monotonic_time(:millisecond) - started_at
      # Generous margin over the 100ms bound: the assertion that matters is
      # "did not wait anywhere near sleep's actual 5s", not a tight bound on
      # scheduler jitter.
      assert elapsed < 2_000
    end

    test "the timeout actually kills the OS process rather than abandoning it" do
      # A fingerprinted duration so pgrep -f finds only the child this call
      # spawned, never some unrelated sleep left over by another test running
      # concurrently (this module is async: true).
      unique_secs = to_string(100_000 + System.unique_integer([:positive]))

      assert {:error, :timeout} = BoundedCommand.run("sleep", [unique_secs], 100)

      # The SIGKILL is sent synchronously before run/3 returns, but the kernel
      # reaping it is not instant.
      Process.sleep(200)

      case System.find_executable("pgrep") do
        nil ->
          :ok

        _found ->
          {output, _status} =
            System.cmd("pgrep", ["-f", "sleep #{unique_secs}"], stderr_to_stdout: true)

          assert String.trim(output) == "",
                 "sleep #{unique_secs} was still running after its timeout killed it"
      end
    end
  end
end
