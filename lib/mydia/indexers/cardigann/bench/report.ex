defmodule Mydia.Indexers.Cardigann.Bench.Report do
  @moduledoc """
  Writes the benchmark output: `bench.json` (everything) and `bench.md` (the
  report attached to the PR).

  `meta` carries run context: `:ref` (Prowlarr/Indexers commit), `:skipped`
  (definitions left out of the corpus and why), `:database`, `:prowlarr_url`.
  Git commits, the Prowlarr tag and the substitution count are read here.
  """

  @substitutions_file "native/cardigann_guest/SUBSTITUTIONS.md"
  @ref_file "native/cardigann_guest/PROWLARR_REF"

  @spec write(map(), [map()], map(), Path.t()) :: {:ok, %{json: Path.t(), md: Path.t()}}
  def write(metrics, results, meta, out_dir) do
    File.mkdir_p!(out_dir)
    info = run_info(meta, metrics)

    json_path = Path.join(out_dir, "bench.json")
    md_path = Path.join(out_dir, "bench.md")

    payload = %{info: info, metrics: metrics, results: results}
    File.write!(json_path, Jason.encode!(jsonable(payload), pretty: true))
    File.write!(md_path, markdown(info, metrics, results))
    {:ok, %{json: json_path, md: md_path}}
  end

  @doc "Renders the Markdown report."
  @spec markdown(map(), map(), [map()]) :: String.t()
  def markdown(info, m, results) do
    [
      header(info, m),
      metrics_table(m),
      m4_section(m),
      health_section(m, results),
      errors_section(results),
      regressions_section(m, results),
      disagreements_section(m),
      resources_section(),
      per_query_section(results)
    ]
    |> Enum.join("\n")
  end

  # -- run info -------------------------------------------------------------

  defp run_info(meta, metrics) do
    %{
      mydia_commit: git(["rev-parse", "HEAD"]),
      mydia_branch: git(["rev-parse", "--abbrev-ref", "HEAD"]),
      rebased_on: git(["merge-base", "HEAD", "origin/master"]),
      origin_master: git(["rev-parse", "origin/master"]),
      prowlarr_tag: prowlarr_tag(),
      indexers_ref: meta[:ref],
      date: Date.utc_today() |> Date.to_iso8601(),
      definitions: metrics.definitions,
      queries: metrics.queries,
      skipped: meta[:skipped] || [],
      substitutions: substitution_count(),
      database: meta[:database],
      prowlarr_url: meta[:prowlarr_url]
    }
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp prowlarr_tag do
    case File.read(@ref_file) do
      {:ok, body} -> body |> String.split() |> List.first() || "unknown"
      _ -> "unknown"
    end
  end

  defp substitution_count do
    case File.read(@substitutions_file) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.take_while(&(not String.starts_with?(&1, "## Added")))
        |> Enum.count(&String.starts_with?(&1, "| src/"))

      _ ->
        nil
    end
  end

  # -- sections -----------------------------------------------------------------

  defp header(info, m) do
    skipped =
      info.skipped
      |> Enum.frequencies_by(&skip_reason/1)
      |> Enum.map_join(", ", fn {reason, n} -> "#{n} #{reason}" end)

    """
    # Cardigann engine benchmark

    | | |
    |---|---|
    | Mydia commit | `#{info.mydia_commit}` (#{info.mydia_branch}) |
    | Rebased on origin/master | `#{info.rebased_on}` (origin/master tip `#{info.origin_master}`) |
    | Prowlarr tag (oracle and guest) | `#{info.prowlarr_tag}` |
    | Prowlarr/Indexers ref | `#{info.indexers_ref}` |
    | Date | #{info.date} |
    | Definitions | #{info.definitions} (#{info.queries} queries) |
    | Left out of the corpus | #{length(info.skipped)} (#{skipped}) |
    | Upstream files substituted by shims | #{info.substitutions} (`#{@substitutions_file}`) |

    Gate verdicts: M1 #{verdict(m.gate.m1)}, M2 #{verdict(m.gate.m2)}, M3 #{verdict(m.gate.m3)}, M4 #{verdict(m.gate.m4)}. M5 and M6 are filled in by the operator below.
    """
  end

  defp skip_reason(%{reason: {kind, _}}), do: kind
  defp skip_reason(%{reason: kind}), do: kind

  defp metrics_table(m) do
    {ea, en} = m.fidelity.elixir
    {wa, wn} = m.fidelity.wasm

    """

    ## Metrics

    | Metric | Elixir | Wasm | Gate | Verdict |
    |---|---|---|---|---|
    | M1 Fidelity (agree with Prowlarr, Jaccard >= 0.95 on every query) | #{ea}/#{en} (#{pct(ea, en)}) | #{wa}/#{wn} (#{pct(wa, wn)}) | wasm > Elixir | #{verdict(m.gate.m1)} |
    | M2 Coverage (>= 1 release) | #{m.coverage.elixir}/#{m.definitions} | #{m.coverage.wasm}/#{m.definitions} | wasm >= Elixir | #{verdict(m.gate.m2)} |
    | M3 Regressions (Elixir agrees, wasm does not) | | #{length(m.regressions)} | zero unexplained | #{verdict(m.gate.m3)} |
    | M4 Engine overhead p50 / p95 (ms, no requestDelay) | #{ms(m.overhead.elixir.p50)} / #{ms(m.overhead.elixir.p95)} (n=#{m.overhead.elixir.n}) | #{ms(m.overhead.wasm.p50)} / #{ms(m.overhead.wasm.p95)} (n=#{m.overhead.wasm.n}) | wasm p95 <= max(2x Elixir, 50 ms) | #{verdict(m.gate.m4)} |

    The M1 denominator is the #{elem(m.fidelity.elixir, 1)} definitions on which Prowlarr returned results; #{length(m.prowlarr_failed)} definitions where Prowlarr errored or returned nothing are excluded from it and listed under Engine health.
    """
  end

  defp m4_section(m) do
    """

    ### How M4 was measured

    Overhead is `wall - network` per ok search, as nearest-rank percentiles. Wall time is the elapsed time of the adapter call in the task that made it.

    - **Wasm**: network is the sum of the host `http-request` import durations, recorded by the host (`HostHttp.exchange`, after the rate-limit throttle) and reported through the `[:mydia, :cardigann, :wasm, :call]` telemetry event, which fires in the calling task. Wall includes waiting for the component to compile, definition parsing, session reads and writes, and the guest's own work.
    - **Elixir**: network is the time inside the `Req.Finch` adapter step, measured by `Bench.NetTimer` installed as the Req `:adapter` through `Req.default_options/1` for the run (Req 0.7.4 emits no telemetry). It is attributed to the calling task and its `$callers`. Req's own request and response steps (decompression, redirects, retry sleeps) and FlareSolverr round trips made outside Req are outside it and count as overhead.
    - **Prowlarr**: only wall time is available. It is not part of M4.
    - Both Mydia engines sleep for a definition's `requestDelay` outside the timed network call. The figure above uses only searches on definitions without a `requestDelay`. Including them: Elixir #{ms(m.overhead_all.elixir.p50)} / #{ms(m.overhead_all.elixir.p95)} ms (n=#{m.overhead_all.elixir.n}), wasm #{ms(m.overhead_all.wasm.p50)} / #{ms(m.overhead_all.wasm.p95)} ms (n=#{m.overhead_all.wasm.n}).
    #{unmeasured_note(m)}
    """
  end

  defp unmeasured_note(m) do
    if m.overhead.elixir.n == 0 do
      "- **The Elixir engine's network time could not be measured in this run (no request went through the timed adapter), so M4 for Elixir is unavailable and the gate falls back to the 50 ms absolute limit.**"
    else
      ""
    end
  end

  defp health_section(m, results) do
    counts =
      for engine <- [:prowlarr, :elixir, :wasm] do
        rows = Enum.map(results, & &1.engines[engine])
        ok = Enum.count(rows, &(&1.status == :ok))
        empty = Enum.count(rows, &(&1.status == :ok and &1.releases == []))

        errors =
          rows |> Enum.reject(&(&1.status == :ok)) |> Enum.frequencies_by(&elem(&1.status, 1))

        silent = Enum.count(rows, &silent_empty?/1)

        "| #{engine} | #{ok} | #{empty} | #{silent} | #{m.empty_with_credentials[engine]} | #{error_kinds(errors)} |"
      end

    """

    ## Engine health

    | Engine | ok searches | ok but empty | empty with no HTTP request made | of which empty_with_credentials | errors by kind |
    |---|---|---|---|---|---|
    #{Enum.join(counts, "\n")}

    "Empty with no HTTP request made" counts ok-but-empty searches whose measured network time is zero: the engine answered without contacting the tracker (Elixir and wasm only), which usually means it gave up before the request.

    `empty_with_credentials` is a private definition with credentials configured that returned no results. Prowlarr and the wasm engine swallow a failed login during search and return an empty list, so this is a possible silent login failure and not a genuine "no results". It is not counted as an error anywhere else.

    Definitions Prowlarr errored or returned nothing on (excluded from M1): #{id_list(m.prowlarr_failed)}
    """
  end

  defp silent_empty?(%{status: :ok, releases: [], network_ms: net}) when is_number(net),
    do: net == 0

  defp silent_empty?(_), do: false

  defp error_kinds(errors) when map_size(errors) == 0, do: "none"
  defp error_kinds(errors), do: Enum.map_join(errors, ", ", fn {k, n} -> "#{k} x#{n}" end)

  defp errors_section(results) do
    rows =
      for r <- results,
          engine <- [:prowlarr, :elixir, :wasm],
          res = r.engines[engine],
          res.status != :ok do
        "| #{r.id} | #{r.query} | #{engine} | #{res.error |> to_string() |> String.replace(~r/[|\n]/, " ") |> String.slice(0, 160)} |"
      end

    case rows do
      [] ->
        ""

      rows ->
        """

        ## Errors

        | Definition | Query | Engine | Error |
        |---|---|---|---|
        #{rows |> Enum.take(60) |> Enum.join("\n")}
        #{if length(rows) > 60, do: "(#{length(rows) - 60} more in bench.json)", else: ""}
        """
    end
  end

  defp regressions_section(%{regressions: []}, _results) do
    "\n## Regressions\n\nNone.\n"
  end

  defp regressions_section(m, results) do
    rows =
      for id <- m.regressions, row <- Enum.filter(results, &(&1.id == id)) do
        "| #{id} | #{row.query} | #{counts(row)} | #{fmt(similarity(row, :elixir))} | #{fmt(similarity(row, :wasm))} | #{status_note(row.engines.wasm)} |"
      end

    """

    ## Regressions

    Elixir agrees with Prowlarr and wasm does not. Each needs a fix or a rerun showing tracker drift.

    | Definition | Query | Releases (Prowlarr / Elixir / wasm) | Jaccard Elixir | Jaccard wasm | Wasm status |
    |---|---|---|---|---|---|
    #{Enum.join(rows, "\n")}
    """
  end

  defp disagreements_section(%{disagreements: []}) do
    "\n## Largest wasm vs Prowlarr disagreements\n\nNone.\n"
  end

  defp disagreements_section(m) do
    rows =
      for d <- m.disagreements do
        "| #{d.id} | #{d.query} | #{d.prowlarr} / #{d.wasm} | #{fmt(d.jaccard)} | #{status_label(d.wasm_status)} | #{titles(d.only_prowlarr)} | #{titles(d.only_wasm)} |"
      end

    """

    ## Largest wasm vs Prowlarr disagreements

    Up to 20, lowest Jaccard first. Titles are the first three releases on only one side.

    | Definition | Query | Releases (Prowlarr / wasm) | Jaccard | Wasm status | Only in Prowlarr | Only in wasm |
    |---|---|---|---|---|---|---|
    #{Enum.join(rows, "\n")}
    """
  end

  defp resources_section do
    """

    ## M5 Resources and M6 Maintenance

    Not computed by this harness. Run the commands listed for the benchmark in the plan (Task 11) and record the results here.

    | Item | Gate | Result |
    |---|---|---|
    | M5 steady-state BEAM RSS delta, pool warm | <= 200 MB | |
    | M5 cold start (component compile at boot) | <= 5 s | |
    | M5 Docker image size delta | <= 60 MB | |
    | M6 Elixir lines deleted at cutover vs C# shim lines added | report | |
    """
  end

  defp per_query_section(results) do
    rows =
      for r <- results do
        e = r.engines

        "| #{r.id} | #{r.type} | #{r.query} | #{cell(e.prowlarr)} | #{cell(e.elixir)} | #{cell(e.wasm)} | #{fmt(similarity(r, :elixir))} | #{fmt(similarity(r, :wasm))} |"
      end

    """

    ## Per-query results

    Cell: releases, or the error kind. `!` marks empty_with_credentials. Jaccard is against Prowlarr.

    | Definition | Type | Query | Prowlarr | Elixir | Wasm | Jaccard Elixir | Jaccard wasm |
    |---|---|---|---|---|---|---|---|
    #{Enum.join(rows, "\n")}
    """
  end

  # -- formatting -----------------------------------------------------------------

  defp verdict(:pass), do: "PASS"
  defp verdict(:fail), do: "FAIL"
  defp verdict(:unmeasured), do: "UNMEASURED"

  defp pct(_a, 0), do: "n/a"
  defp pct(a, b), do: "#{Float.round(a / b * 100, 1)}%"

  defp ms(nil), do: "n/a"
  defp ms(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp fmt(nil), do: "n/a"
  defp fmt(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp counts(row) do
    [:prowlarr, :elixir, :wasm]
    |> Enum.map_join(" / ", fn e -> cell(row.engines[e]) end)
  end

  defp cell(%{status: :ok, releases: releases} = r),
    do: "#{length(releases)}#{if r[:empty_with_credentials], do: "!", else: ""}"

  defp cell(%{status: {:error, kind}}), do: "err:#{kind}"

  defp status_note(%{status: :ok}), do: "ok"
  defp status_note(%{status: {:error, kind}} = r), do: "error #{kind}: #{r[:error]}"

  defp status_label(:ok), do: "ok"
  defp status_label({:error, kind}), do: "error #{kind}"

  defp titles(list), do: Enum.map_join(list, "; ", &String.replace(to_string(&1), "|", "/"))

  defp id_list([]), do: "none"
  defp id_list(ids), do: Enum.join(ids, ", ")

  defp similarity(row, engine) do
    if row.engines.prowlarr.status == :ok and row.engines[engine].status == :ok and
         row.engines.prowlarr.releases != [] do
      Mydia.Indexers.Cardigann.Bench.Metrics.similarity(row, engine)
    end
  end

  # -- json ---------------------------------------------------------------------------

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%{__struct__: _} = s), do: s |> Map.from_struct() |> jsonable()
  defp jsonable(%{} = map), do: Map.new(map, fn {k, v} -> {json_key(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable({a, b}) when is_integer(a) and is_integer(b), do: [a, b]
  defp jsonable(tuple) when is_tuple(tuple), do: inspect(tuple)
  defp jsonable(other), do: other

  defp json_key(k) when is_atom(k) or is_binary(k) or is_integer(k), do: k
  defp json_key(k), do: inspect(k)
end
