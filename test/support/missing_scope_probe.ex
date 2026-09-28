defmodule MydiaWeb.MissingScopeProbe do
  @moduledoc """
  Forwards `[:mydia, :media_access, :missing_scope]` events to the test that
  attached the probe, as `{:missing_scope, metadata}`.

  Telemetry handlers are global, so the handler only forwards events emitted
  from the attaching process. `Phoenix.ConnTest` dispatches requests in the
  test process, so every request a test makes emits from its own pid, and an
  async neighbour's events are ignored.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @event [:mydia, :media_access, :missing_scope]

  @spec attach() :: :ok
  def attach do
    test_pid = self()
    handler_id = {__MODULE__, test_pid}

    :ok = :telemetry.attach(handler_id, @event, &__MODULE__.handle_event/4, test_pid)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  @doc false
  def handle_event(_event, _measurements, metadata, test_pid) do
    if self() == test_pid, do: send(test_pid, {:missing_scope, metadata})
  end
end
