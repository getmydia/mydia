defmodule Mydia.DeadCode.TracerTest do
  # async: false — the tracer uses a named ETS table and a global compiler option.
  use ExUnit.Case, async: false

  alias Mydia.DeadCode.Tracer

  setup do
    Tracer.start()
    Code.put_compiler_option(:tracers, [Tracer])

    on_exit(fn ->
      Code.put_compiler_option(:tracers, [])
      Tracer.stop()
    end)

    :ok
  end

  defp compile(source, file) do
    Code.compile_string(source, file)
  end

  test "records the file each module is defined in" do
    compile(
      """
      defmodule TracerFixture.Alpha do
        def x, do: 1
      end
      """,
      "lib/tracer_fixture/alpha.ex"
    )

    assert Tracer.definitions()[TracerFixture.Alpha] == "lib/tracer_fixture/alpha.ex"
  end

  test "records both modules when one file defines two" do
    compile(
      """
      defmodule TracerFixture.Multi.A do
        def x, do: 1
      end

      defmodule TracerFixture.Multi.B do
        def y, do: 2
      end
      """,
      "lib/tracer_fixture/multi.ex"
    )

    definitions = Tracer.definitions()
    assert definitions[TracerFixture.Multi.A] == "lib/tracer_fixture/multi.ex"
    assert definitions[TracerFixture.Multi.B] == "lib/tracer_fixture/multi.ex"
  end

  test "resolves an alias rename back to the real module" do
    compile(
      """
      defmodule TracerFixture.Target do
        defstruct [:x]
        def hello, do: :world
      end
      """,
      "lib/tracer_fixture/target.ex"
    )

    compile(
      """
      defmodule TracerFixture.Caller do
        alias TracerFixture.Target, as: Renamed
        def go, do: Renamed.hello()
      end
      """,
      "lib/tracer_fixture/caller.ex"
    )

    callers =
      Tracer.edges()
      |> Enum.filter(fn {callee, _file} -> callee == TracerFixture.Target end)
      |> Enum.map(fn {_callee, file} -> file end)

    assert "lib/tracer_fixture/caller.ex" in callers
  end

  test "records a module referenced only as a value" do
    compile(
      """
      defmodule TracerFixture.Adapter do
        def run, do: :ok
      end
      """,
      "lib/tracer_fixture/adapter.ex"
    )

    compile(
      """
      defmodule TracerFixture.Registrar do
        def register, do: {:adapter, TracerFixture.Adapter}
      end
      """,
      "lib/tracer_fixture/registrar.ex"
    )

    callers =
      Tracer.edges()
      |> Enum.filter(fn {callee, _file} -> callee == TracerFixture.Adapter end)
      |> Enum.map(fn {_callee, file} -> file end)

    assert "lib/tracer_fixture/registrar.ex" in callers
  end
end
