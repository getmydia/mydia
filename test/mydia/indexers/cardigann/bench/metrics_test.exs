defmodule Mydia.Indexers.Cardigann.Bench.MetricsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Bench.{Metrics, Release}

  defp rel(title), do: %Release{title: title, size: 1}

  defp ok(titles, extra \\ %{}),
    do: Map.merge(%{status: :ok, releases: Enum.map(titles, &rel/1)}, extra)

  defp row(id, engines, extra \\ []) do
    %{
      id: id,
      type: Keyword.get(extra, :type, "public"),
      query: Keyword.get(extra, :query, "q"),
      engines: Map.new(engines)
    }
  end

  test "fidelity excludes definitions prowlarr fails on, regressions list elixir-only agreement" do
    results = [
      row("a", prowlarr: ok(["x", "y"]), elixir: ok(["x", "y"]), wasm: ok(["x", "y"])),
      row("b", prowlarr: ok(["x"]), elixir: ok(["x"]), wasm: ok([])),
      row("c", prowlarr: ok(["x"]), elixir: ok([]), wasm: ok(["x"])),
      row("d",
        prowlarr: %{status: {:error, :http}, releases: []},
        elixir: ok(["z"]),
        wasm: ok([])
      )
    ]

    m = Metrics.compute(results)
    assert m.fidelity == %{elixir: {2, 3}, wasm: {2, 3}}
    assert m.coverage == %{elixir: 3, wasm: 2}
    assert m.regressions == ["b"]
    assert m.definitions == 4
    assert m.prowlarr_failed == ["d"]
  end

  test "verified names the engines that agreed with prowlarr, in app terms" do
    results = [
      row("a", prowlarr: ok(["x"]), elixir: ok(["x"]), wasm: ok(["x"])),
      row("b", prowlarr: ok(["x"]), elixir: ok(["y"]), wasm: ok(["x"])),
      row("c", prowlarr: ok([]), elixir: ok(["x"]), wasm: ok(["x"]))
    ]

    assert Metrics.compute(results).verified == %{
             "a" => [:builtin, :prowlarr],
             "b" => [:prowlarr]
           }
  end

  test "a definition agrees only if every query agrees" do
    results = [
      row("a", [prowlarr: ok(["x"]), elixir: ok(["x"]), wasm: ok(["x"])], query: "q1"),
      row("a", [prowlarr: ok(["x"]), elixir: ok(["x"]), wasm: ok(["y"])], query: "q2")
    ]

    m = Metrics.compute(results)
    assert m.fidelity == %{elixir: {1, 1}, wasm: {0, 1}}
    assert m.regressions == ["a"]
  end

  test "agreement threshold is jaccard >= 0.95" do
    big = Enum.map(1..20, &"t#{&1}")

    m =
      Metrics.compute([
        row("a", prowlarr: ok(big), elixir: ok(Enum.take(big, 19)), wasm: ok(big))
      ])

    assert m.fidelity.elixir == {1, 1}

    m =
      Metrics.compute([
        row("a", prowlarr: ok(big), elixir: ok(Enum.take(big, 18)), wasm: ok(big))
      ])

    assert m.fidelity.elixir == {0, 1}
  end

  test "empty_with_credentials is counted per engine, apart from plain empty" do
    results = [
      row("p",
        prowlarr: ok(["x"]),
        elixir: ok(["x"]),
        wasm: ok([], %{empty_with_credentials: true})
      ),
      row("q", prowlarr: ok([]), elixir: ok([]), wasm: ok([]))
    ]

    m = Metrics.compute(results)
    assert m.empty_with_credentials == %{prowlarr: 0, elixir: 0, wasm: 1}
  end

  test "engine overhead is wall minus network, percentiles over ok searches" do
    mk = fn wall, net -> ok(["x"], %{wall_ms: wall, network_ms: net}) end

    results =
      for {w, n} <- [{100.0, 90.0}, {200.0, 150.0}, {300.0, 250.0}, {1000.0, 900.0}] do
        row("d#{w}", prowlarr: ok(["x"]), elixir: mk.(w + 10, n), wasm: mk.(w, n))
      end

    m = Metrics.compute(results)
    # overheads 10 50 50 100: nearest rank p50 = 50, p95 = 100
    assert m.overhead.wasm == %{p50: 50.0, p95: 100.0, n: 4}
    assert m.overhead.elixir.n == 4
  end

  test "overhead is unmeasured when an engine has no network time" do
    results = [row("a", prowlarr: ok(["x"]), elixir: ok(["x"], %{wall_ms: 5.0}), wasm: ok(["x"]))]
    assert Metrics.compute(results).overhead.elixir == %{p50: nil, p95: nil, n: 0}
  end

  test "gate verdicts" do
    results = [
      row("a", prowlarr: ok(["x"]), elixir: ok([]), wasm: ok(["x"])),
      row("b", prowlarr: ok(["x"]), elixir: ok(["x"]), wasm: ok(["x"]))
    ]

    gate = Metrics.compute(results).gate
    assert gate.m1 == :pass
    assert gate.m2 == :pass
    assert gate.m3 == :pass
    assert gate.m4 == :insufficient
  end

  defp paired_rows(n, wasm_overhead, elixir_overhead) do
    for i <- 1..n do
      timed = fn overhead -> ok(["x"], %{wall_ms: 100.0 + overhead, network_ms: 100.0}) end

      row("p#{i}",
        prowlarr: ok(["x"]),
        elixir: timed.(elixir_overhead),
        wasm: timed.(wasm_overhead)
      )
    end
  end

  test "m4 gates on paired searches only, and reports n" do
    m = Metrics.compute(paired_rows(10, 20.0, 10.0))
    assert m.paired_n == 10
    assert m.gate.m4 == :pass
    assert Metrics.compute(paired_rows(10, 120.0, 10.0)).gate.m4 == :fail
  end

  test "m4 is insufficient under 10 paired searches, even when wasm is slow" do
    m = Metrics.compute(paired_rows(9, 500.0, 10.0))
    assert m.paired_n == 9
    assert m.gate.m4 == :insufficient
  end

  test "searches where prowlarr or an engine returned nothing are not paired" do
    timed = ok(["x"], %{wall_ms: 10.0, network_ms: 5.0})

    rows =
      paired_rows(10, 20.0, 10.0) ++
        [
          row("e",
            prowlarr: ok(["x"]),
            elixir: ok([], %{wall_ms: 1.0, network_ms: 0.0}),
            wasm: timed
          ),
          row("f", prowlarr: ok([]), elixir: timed, wasm: timed),
          row("g", [prowlarr: ok(["x"]), elixir: timed, wasm: timed], type: "public")
          |> Map.put(:request_delay_ms, 2000)
        ]

    m = Metrics.compute(rows)
    assert m.paired_n == 10
    # the unpaired diagnostic still sees every delay-free ok search
    assert m.overhead_unpaired.wasm.n == 12
    assert m.overhead_all.wasm.n == 13
  end

  describe "lenient matcher rule" do
    defp sized(title, size), do: %Release{title: title, size: size}

    defp srow(id, prowlarr_size, engine_size) do
      p = %{status: :ok, releases: [sized("x", prowlarr_size)]}
      e = %{status: :ok, releases: [sized("x", engine_size)]}
      row(id, prowlarr: p, elixir: e, wasm: p)
    end

    test "a size missing on one side fails strictly and agrees leniently" do
      m = Metrics.compute([srow("a", 1000, nil), srow("b", 1000, 1000)])
      assert m.fidelity.elixir == {1, 2}
      assert m.fidelity_lenient.elixir == {2, 2}
      assert m.fidelity.wasm == {2, 2}
      assert m.rule_differences == [%{id: "a", engine: :elixir, strict: false, lenient: true}]
    end

    test "regressions are also reported under the lenient rule" do
      p = %{status: :ok, releases: [sized("x", 1000)]}

      strict_regression =
        row("r", prowlarr: p, wasm: %{p | releases: [sized("x", nil)]}, elixir: p)

      m = Metrics.compute([strict_regression])
      assert m.regressions == ["r"]
      assert m.regressions_lenient == []
    end
  end

  test "gate fails when wasm fidelity does not exceed elixir" do
    results = [row("a", prowlarr: ok(["x"]), elixir: ok(["x"]), wasm: ok(["x"]))]
    assert Metrics.compute(results).gate.m1 == :fail
  end
end
