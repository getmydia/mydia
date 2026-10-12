defmodule Mydia.Indexers.Cardigann.FakeWasmEngine do
  @moduledoc """
  Stands in for `Mydia.Indexers.Cardigann.Wasm.Engine` under the switcher in
  tests. Calls are reported to the pid in `:fake_wasm_engine_pid`, and
  `status/0` answers `:fake_wasm_engine_status` (default `:pending`). Tests
  drive progress by broadcasting on `Wasm.Engine.topic/0`.
  """

  def ensure_started, do: report(:ensure_started)
  def stop, do: report(:stop)
  def retry_now, do: report(:retry_now)
  def status, do: Application.get_env(:mydia, :fake_wasm_engine_status, :pending)

  defp report(call) do
    if pid = Application.get_env(:mydia, :fake_wasm_engine_pid),
      do: send(pid, {:fake_engine, call})

    :ok
  end
end
