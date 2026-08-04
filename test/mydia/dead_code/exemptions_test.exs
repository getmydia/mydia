defmodule Mydia.DeadCode.ExemptionsTest do
  use ExUnit.Case, async: true

  alias Mydia.DeadCode.Exemptions

  test "Mix tasks are exempt because Mix dispatches them by name" do
    assert Exemptions.exempt?(Mix.Tasks.Mydia.DeadCode)
  end

  test "Ecto migrations are exempt because the migrator dispatches them" do
    assert Exemptions.exempt?(Mydia.Repo.Migrations.SomeMigration)
  end

  test "a behaviour implementation is exempt because its dispatcher is external" do
    # Mydia.Repo implements the Ecto.Repo behaviour.
    assert Exemptions.exempt?(Mydia.Repo)
  end

  test "an ordinary application module is not exempt" do
    refute Exemptions.exempt?(Mydia.DeadCode.Graph)
  end

  test "an unloadable module is not exempt rather than crashing" do
    refute Exemptions.exempt?(:"Elixir.Definitely.Not.A.Real.Module")
  end
end
