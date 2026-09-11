defmodule Mydia.BoundedCommand do
  @moduledoc """
  Runs an external command under a hard wall-clock bound.

  `System.cmd/3` blocks until the child exits and never hands the caller an OS
  pid, so `Task.shutdown/2` around it only abandons the handle while the child
  keeps running. This opens a Port and tracks the child's OS pid instead, the
  same shape `FfmpegHlsTranscoder.start_ffmpeg_process/1` uses, so an expired
  deadline actually SIGKILLs the child rather than leaving it orphaned.

  stderr is merged into the returned output.
  """

  @type error :: {:exit, integer(), binary()} | :timeout | :not_found

  @doc """
  Runs `name` with `args`, killing it if it has not exited within `timeout`
  milliseconds.

  `name` goes through `System.find_executable/1`, so a bare name resolved on
  PATH and an absolute path both work.
  """
  @spec run(String.t(), [String.t()], timeout()) :: {:ok, binary()} | {:error, error()}
  def run(name, args, timeout) do
    case System.find_executable(name) do
      nil ->
        {:error, :not_found}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            :hide,
            args: args
          ])

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, os_pid} -> os_pid
            nil -> nil
          end

        # An absolute deadline, not a per-receive timeout. `after` applies to
        # each `receive`, so passing the bound straight down would restart the
        # whole window on every {:data, _} chunk, and a child that hangs while
        # still writing output would run indefinitely -- exactly the case this
        # bound exists to stop.
        deadline =
          case timeout do
            :infinity -> :infinity
            ms -> System.monotonic_time(:millisecond) + ms
          end

        collect(port, os_pid, "", deadline)
    end
  end

  defp collect(port, os_pid, buffer, deadline) do
    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, buffer <> data, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, buffer}

      {^port, {:exit_status, code}} ->
        {:error, {:exit, code, buffer}}
    after
      remaining_ms(deadline) ->
        kill(port, os_pid)
        {:error, :timeout}
    end
  end

  defp remaining_ms(:infinity), do: :infinity

  defp remaining_ms(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  # Closing the port stops it relaying further messages, but does not by
  # itself terminate a running child -- Erlang's default port behaviour on
  # close is to keep the OS process alive when the driver was opened with
  # :spawn_executable. SIGKILL via the same `kill -9` mechanism the
  # transcoders use is what actually ends it.
  defp kill(port, os_pid) do
    if os_pid, do: System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end
end
