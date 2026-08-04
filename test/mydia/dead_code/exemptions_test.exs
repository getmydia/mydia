defmodule Mydia.DeadCode.ExemptionsTest do
  use ExUnit.Case, async: true

  alias Mydia.DeadCode.Exemptions

  defmodule NotDispatchOnly do
    @moduledoc false
    @callback run() :: :ok
  end

  defmodule OrdinaryBehaviourImpl do
    @moduledoc false
    @behaviour Mydia.DeadCode.ExemptionsTest.NotDispatchOnly

    @impl true
    def run, do: :ok
  end

  test "Mix tasks are exempt because Mix dispatches them by name" do
    assert Exemptions.exempt?(Mix.Tasks.Mydia.DeadCode)
  end

  test "Ecto migrations are exempt because the migrator dispatches them" do
    assert Exemptions.exempt?(Mydia.Repo.Migrations.SomeMigration)
  end

  test "the OTP application module is exempt because mix.exs names it, not lib/" do
    assert Exemptions.exempt?(Mydia.Application)
  end

  test "an Oban worker is exempt because cron config dispatches it from outside lib/" do
    # Scheduler workers are named only in config/*.exs cron entries, which the
    # tracer never sees. Pick any module in the app that `use Oban.Worker`.
    assert Exemptions.exempt?(Mydia.Jobs.LibraryScanScheduler)
  end

  test "an ordinary application module is not exempt" do
    refute Exemptions.exempt?(Mydia.DeadCode.Graph)
  end

  # Regression guard. An earlier revision exempted every module declaring any
  # behaviour, which made 47 LiveViews and 22 GenServers permanent roots and
  # hid exactly the dead code this tool exists to find. Wired LiveViews and
  # supervised GenServers stay live by reachability, not by exemption.
  test "implementing a non-dispatch-only behaviour does not confer exemption" do
    refute Exemptions.exempt?(OrdinaryBehaviourImpl)
  end

  test "a GenServer is not exempt merely for being a GenServer" do
    # Supervised GenServers are reachable from Application's child list.
    # An unsupervised one is dead, and must be reportable as dead.
    refute Exemptions.exempt?(Mydia.DeadCode.ExemptionsTest.GenServerFixture)
  end

  test "an unloadable module is not exempt rather than crashing" do
    refute Exemptions.exempt?(:"Elixir.Definitely.Not.A.Real.Module")
  end
end

defmodule Mydia.DeadCode.ExemptionsTest.GenServerFixture do
  @moduledoc false
  use GenServer

  @impl true
  def init(state), do: {:ok, state}
end
