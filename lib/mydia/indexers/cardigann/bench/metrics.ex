defmodule Mydia.Indexers.Cardigann.Bench.Metrics do
  @moduledoc """
  M1 to M4 of the Cardigann benchmark, plus the merge-gate verdict per item.

  Input is a list of result rows, one per definition and query:

      %{
        id: "definition-id",
        type: "public" | "private" | "semi-private",
        query: "label",
        engines: %{prowlarr: result, elixir: result, wasm: result}
      }

  where a `result` is `%{status: :ok | {:error, term}, releases: [Release.t()]}`,
  optionally with `:wall_ms`, `:network_ms` and `:empty_with_credentials`.

  Rows of one definition are aggregated: a definition "agrees" with Prowlarr
  when every query Prowlarr succeeded on (ok and at least one release) has a
  Jaccard similarity of at least 0.95. A definition with no such query is
  excluded from the fidelity denominator.

  The gate uses the strict matcher rule. `fidelity_lenient`,
  `regressions_lenient` and `rule_differences` are diagnostics under the lenient
  rule (a size known on one side only counts as a size match).

  A row may carry `:request_delay_ms`. The gating M4 (`overhead`) is computed
  over paired searches only: no request delay, and Prowlarr, Elixir and wasm all
  ok with results. Under 10 such searches the verdict is `:insufficient`.
  `overhead_unpaired` (every delay-free row) and `overhead_all` are diagnostics.

  M5 (resources) and M6 (maintenance) are not computed here.
  """

  alias Mydia.Indexers.Cardigann.Bench.Matcher

  @agree_threshold 0.95
  @engines [:elixir, :wasm]
  @all_engines [:prowlarr, :elixir, :wasm]
  @overhead_floor_ms 50.0

  @spec agree_threshold() :: float()
  def agree_threshold, do: @agree_threshold

  @spec compute([map()]) :: map()
  def compute(rows) do
    by_def = rows |> Enum.group_by(& &1.id) |> Enum.sort_by(&elem(&1, 0))

    judged = for {id, rs} <- by_def, j <- [judged_rows(rs)], j != [], do: {id, j}
    prowlarr_failed = for {id, rs} <- by_def, judged_rows(rs) == [], do: id

    fidelity = fidelity(judged, [])
    fidelity_lenient = fidelity(judged, lenient: true)

    coverage = Map.new(@engines, fn e -> {e, Enum.count(by_def, &covered?(&1, e))} end)

    regressions = regressions(judged, [])
    regressions_lenient = regressions(judged, lenient: true)

    delay_free = Enum.filter(rows, &no_delay?/1)
    paired = Enum.filter(delay_free, &paired?/1)

    metrics = %{
      definitions: length(by_def),
      queries: length(rows),
      prowlarr_failed: prowlarr_failed,
      fidelity: fidelity,
      coverage: coverage,
      regressions: regressions,
      fidelity_lenient: fidelity_lenient,
      regressions_lenient: regressions_lenient,
      rule_differences: rule_differences(judged),
      empty_with_credentials: empty_with_credentials(rows),
      paired_n: length(paired),
      overhead: Map.new(@engines, fn e -> {e, overhead(paired, e)} end),
      overhead_unpaired: Map.new(@engines, fn e -> {e, overhead(delay_free, e)} end),
      overhead_all: Map.new(@engines, fn e -> {e, overhead(rows, e)} end),
      disagreements: disagreements(rows, 20),
      verified: verified(judged)
    }

    Map.put(metrics, :gate, gate(metrics))
  end

  @doc "Jaccard similarity of the engine's releases against Prowlarr's for one row."
  @spec similarity(map(), atom(), keyword()) :: float()
  def similarity(row, engine, opts \\ []) do
    Matcher.jaccard(row.engines.prowlarr.releases, row.engines[engine].releases, opts)
  end

  defp fidelity(judged, opts) do
    Map.new(@engines, fn engine ->
      agreeing = Enum.count(judged, fn {_id, j} -> agrees?(j, engine, opts) end)
      {engine, {agreeing, length(judged)}}
    end)
  end

  defp regressions(judged, opts) do
    for {id, j} <- judged, agrees?(j, :elixir, opts), not agrees?(j, :wasm, opts), do: id
  end

  @engine_names %{elixir: :builtin, wasm: :prowlarr}

  # Per definition, the engines that agreed with Prowlarr on every judged query,
  # named as the app names them. Printed for Mydia.Indexers.Cardigann.EngineSupport.
  defp verified(judged) do
    for {id, j} <- judged,
        engines = for(e <- @engines, agrees?(j, e, []), do: @engine_names[e]),
        engines != [],
        into: %{},
        do: {id, engines}
  end

  # Definitions whose agreement with Prowlarr differs between the strict
  # (gating) and the lenient matcher rule, per engine.
  defp rule_differences(judged) do
    for {id, j} <- judged,
        engine <- @engines,
        strict <- [agrees?(j, engine, [])],
        lenient <- [agrees?(j, engine, lenient: true)],
        strict != lenient do
      %{id: id, engine: engine, strict: strict, lenient: lenient}
    end
  end

  # Prowlarr succeeded: ok with at least one release.
  defp judged_rows(rows) do
    Enum.filter(rows, fn r ->
      p = r.engines.prowlarr
      p.status == :ok and p.releases != []
    end)
  end

  defp agrees?(judged, engine, opts) do
    Enum.all?(judged, fn r ->
      result = r.engines[engine]
      result.status == :ok and similarity(r, engine, opts) >= @agree_threshold
    end)
  end

  defp covered?({_id, rows}, engine) do
    Enum.any?(rows, fn r ->
      result = r.engines[engine]
      result.status == :ok and result.releases != []
    end)
  end

  defp empty_with_credentials(rows) do
    Map.new(@all_engines, fn engine ->
      {engine, Enum.count(rows, &(r_flag(&1, engine) == true))}
    end)
  end

  defp r_flag(row, engine), do: row.engines[engine][:empty_with_credentials]

  # -- M4 ------------------------------------------------------------------

  # A definition's `requestDelay` makes the wasm host (RateLimiter) sleep outside
  # the timed network call, so that sleep lands in "wall minus network" for wasm.
  # The Elixir engine never honours it (its parser reads the key `requestdelay`,
  # and every definition spells it `requestDelay`), so the delay would bias M4
  # against wasm only. Rows with a delay are therefore excluded from the gating
  # figure; `overhead_all` keeps the raw figure.
  defp no_delay?(row), do: (row[:request_delay_ms] || 0) == 0

  # The gating M4 sample: one (definition, query) where all three engines
  # answered with results, so both engines are timed on the same searches.
  defp paired?(row) do
    Enum.all?(@all_engines, fn e ->
      r = row.engines[e]
      r.status == :ok and r.releases != []
    end) and
      Enum.all?(@engines, fn e ->
        r = row.engines[e]
        is_number(r[:wall_ms]) and is_number(r[:network_ms])
      end)
  end

  defp overhead(rows, engine) do
    samples =
      for r <- rows,
          result <- [r.engines[engine]],
          result.status == :ok,
          is_number(result[:wall_ms]),
          is_number(result[:network_ms]),
          do: max(result.wall_ms - result.network_ms, 0.0)

    case Enum.sort(samples) do
      [] -> %{p50: nil, p95: nil, n: 0}
      sorted -> %{p50: percentile(sorted, 0.50), p95: percentile(sorted, 0.95), n: length(sorted)}
    end
  end

  # Nearest rank.
  defp percentile(sorted, p) do
    rank = max(ceil(p * length(sorted)), 1)
    sorted |> Enum.at(rank - 1) |> Kernel.*(1.0)
  end

  # -- disagreements ---------------------------------------------------------

  defp disagreements(rows, limit) do
    rows
    |> Enum.filter(&(&1.engines.prowlarr.status == :ok and &1.engines.prowlarr.releases != []))
    |> Enum.map(fn r ->
      wasm = r.engines.wasm
      diff = Matcher.diff(r.engines.prowlarr.releases, wasm.releases)

      %{
        id: r.id,
        query: r.query,
        jaccard: similarity(r, :wasm),
        prowlarr: length(r.engines.prowlarr.releases),
        wasm: length(wasm.releases),
        wasm_status: wasm.status,
        only_prowlarr: titles(diff.only_left),
        only_wasm: titles(diff.only_right)
      }
    end)
    |> Enum.filter(&(&1.jaccard < 1.0))
    |> Enum.sort_by(&{&1.jaccard, -abs(&1.prowlarr - &1.wasm), &1.id})
    |> Enum.take(limit)
  end

  defp titles(releases), do: releases |> Enum.take(3) |> Enum.map(& &1.title)

  # -- gate ------------------------------------------------------------------

  defp gate(m) do
    %{
      m1: gate_m1(m.fidelity),
      m2: if(m.coverage.wasm >= m.coverage.elixir, do: :pass, else: :fail),
      m3: if(m.regressions == [], do: :pass, else: :fail),
      m4: gate_m4(m.overhead, m.paired_n)
    }
  end

  @min_paired 10

  defp gate_m1(%{elixir: {ea, en}, wasm: {wa, wn}}) when en > 0 and wn > 0 do
    # wa/wn > ea/en without division
    if wa * en > ea * wn, do: :pass, else: :fail
  end

  defp gate_m1(_), do: :unmeasured

  # Fewer than @min_paired paired searches is not evidence either way. Paired
  # samples always carry both engines' network time, so an unmeasured Elixir
  # p95 cannot occur once the sample is large enough.
  defp gate_m4(_overhead, paired_n) when paired_n < @min_paired, do: :insufficient

  defp gate_m4(%{wasm: %{p95: wasm}, elixir: %{p95: elixir}}, _paired_n)
       when is_number(wasm) and is_number(elixir),
       do: if(wasm <= max(2 * elixir, @overhead_floor_ms), do: :pass, else: :fail)

  defp gate_m4(_overhead, _paired_n), do: :insufficient
end
