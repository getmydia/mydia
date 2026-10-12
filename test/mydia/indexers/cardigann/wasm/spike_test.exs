defmodule Mydia.Indexers.Cardigann.Wasm.SpikeTest do
  # Measures whether Prowlarr's engine runs under Wasmex at all. Tagged so the
  # normal suite skips it: run with `--include cardigann_spike`.
  use ExUnit.Case, async: false

  @moduletag timeout: 900_000
  @wasm Path.expand("../../../../../native/cardigann_guest/out/cardigann.wasm", __DIR__)
  @fixtures Path.expand("../../../../support/fixtures/cardigann_wasm", __DIR__)
  @engine ["mydia:cardigann/engine@1.0.0", "search"]

  alias Wasmex.Components
  alias Wasmex.Wasi.WasiP2Options

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, bytes: File.read!(@wasm)}
  end

  defp definition(name, bypass) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.replace(~r{https://[a-z]+\.invalid/}, "http://localhost:#{bypass.port}/")
  end

  defp imports do
    %{
      "mydia:cardigann/host@1.0.0" => %{
        "http-request" =>
          {:fn,
           fn req ->
             headers = Enum.map(req.headers, &{&1.name, &1.value})

             body =
               case req.body do
                 {:some, bytes} -> IO.iodata_to_binary(bytes)
                 :none -> nil
               end

             case Req.request(
                    method: req.method |> String.downcase() |> String.to_existing_atom(),
                    url: req.url,
                    headers: headers,
                    body: body,
                    redirect: false,
                    retry: false,
                    decode_body: false
                  ) do
               {:ok, resp} ->
                 {:ok,
                  %{
                    status: resp.status,
                    headers:
                      for({k, vs} <- resp.headers, v <- List.wrap(vs), do: %{name: k, value: v}),
                    # list<u8> crosses the boundary as a list of integers
                    body: :binary.bin_to_list(resp.body)
                  }}

               {:error, e} ->
                 {:error, {:connect, Exception.message(e)}}
             end
           end},
        "log" => {:fn, fn _level, _msg -> :ok end}
      }
    }
  end

  # Same lockdown as Mydia.Plugins.Host. The component imports no wasi:http or
  # wasi:sockets (build.sh composes trapping stand-ins under it), so it links
  # without allow_http; see "Sandbox lock" in native/cardigann_guest/SPIKE.md.
  defp wasi,
    do: %WasiP2Options{
      inherit_stdin: false,
      inherit_stdout: false,
      inherit_stderr: false,
      allow_http: false
    }

  defp start(bytes) do
    {t, {:ok, pid}} =
      :timer.tc(fn ->
        Components.start_link(%{bytes: bytes, wasi: wasi(), imports: imports()})
      end)

    Process.unlink(pid)
    {pid, div(t, 1000)}
  end

  @empty_session %{cookies: [], "expires-unix": :none}

  defp query do
    %{
      kind: :search,
      term: "harbor",
      categories: [],
      "imdb-id": :none,
      "tmdb-id": :none,
      "tvdb-id": :none,
      season: :none,
      episode: :none,
      limit: :none,
      offset: :none
    }
  end

  defp stub_search(bypass) do
    Bypass.stub(bypass, "GET", "/search", fn conn ->
      Plug.Conn.resp(conn, 200, File.read!(Path.join(@fixtures, "lantern-search.html")))
    end)
  end

  defp search(pid, bypass) do
    Components.call_function(
      pid,
      @engine,
      [definition("lantern-public.yml", bypass), [], query(), @empty_session],
      30_000
    )
  end

  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))

  defp vm_rss_kb do
    "/proc/self/status"
    |> File.read!()
    |> then(&Regex.run(~r/VmRSS:\s+(\d+) kB/, &1))
    |> Enum.at(1)
    |> String.to_integer()
  end

  @tag :cardigann_spike
  test "public search returns releases", %{bypass: bypass, bytes: bytes} do
    stub_search(bypass)
    {pid, start_ms} = start(bytes)

    {call_us, result} = :timer.tc(fn -> search(pid, bypass) end)
    IO.puts("spike: raw result shape: #{inspect(result, limit: :infinity, printable_limit: 60)}")

    with {:error, msg} when is_binary(msg) <- result,
         do: IO.puts("spike: error tail: #{String.slice(msg, -700, 700)}")

    assert {:ok, {:ok, %{releases: releases}}} = normalize(result)
    assert length(releases) == 2
    IO.puts("spike: start=#{start_ms}ms search=#{div(call_us, 1000)}ms")
    Process.exit(pid, :kill)
  end

  @tag :cardigann_spike
  test "form login returns a session cookie", %{bypass: bypass, bytes: bytes} do
    Bypass.stub(bypass, "GET", "/login.php", fn conn ->
      Plug.Conn.resp(conn, 200, File.read!(Path.join(@fixtures, "quill-login-page.html")))
    end)

    Bypass.stub(bypass, "POST", "/takelogin.php", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/index.php")
      |> Plug.Conn.put_resp_header("set-cookie", "sid=abc123; Path=/")
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.stub(bypass, "GET", "/index.php", fn conn ->
      Plug.Conn.resp(conn, 200, ~s(<a href="logout.php">logout</a>))
    end)

    {pid, _} = start(bytes)

    settings = [%{name: "username", value: "reader"}, %{name: "password", value: "secret"}]

    result =
      Components.call_function(
        pid,
        ["mydia:cardigann/engine@1.0.0", "login"],
        [definition("quill-login.yml", bypass), settings, @empty_session, :none],
        30_000
      )

    IO.puts("spike: raw login result: #{inspect(result, limit: 12, printable_limit: 80)}")
    assert {:ok, {:ok, {:ok, %{cookies: cookies}}}} = normalize(result)
    assert %{name: "sid", value: "abc123"} in cookies
    Process.exit(pid, :kill)
  end

  @tag :cardigann_spike
  test "measures compile and instantiate separately", %{bypass: bypass, bytes: bytes} do
    stub_search(bypass)

    compile_ms =
      for _ <- 1..3 do
        {:ok, store} = Components.Store.new_wasi(wasi())
        {t, {:ok, _}} = :timer.tc(fn -> Components.Component.new(store, bytes) end)
        div(t, 1000)
      end

    # Engine.default/0 builds a NEW engine per call, and a component can only be
    # instantiated in a store of the engine that compiled it (a store built with
    # its own default engine fails: "cross-`Engine` instantiation is not
    # currently supported"). Share one engine explicitly.
    shared = Wasmex.Engine.default()
    {:ok, store0} = Components.Store.new_wasi(wasi(), nil, shared)
    {:ok, compiled} = Components.Component.new(store0, bytes)

    reuse =
      for i <- 1..20 do
        {:ok, store} = Components.Store.new_wasi(wasi(), nil, shared)

        {t, res} =
          :timer.tc(fn ->
            GenServer.start_link(Components, %{
              store: store,
              component: compiled,
              imports: imports()
            })
          end)

        case res do
          {:ok, pid} ->
            Process.unlink(pid)
            # a reused-component instance must actually serve calls
            if i == 1, do: assert({:ok, {:ok, %{releases: [_, _]}}} = search(pid, bypass))
            Process.exit(pid, :kill)
            {:ok, div(t, 1000)}

          other ->
            {:error, other}
        end
      end

    reuse_report =
      case Enum.filter(reuse, &match?({:error, _}, &1)) do
        [] -> "#{median(for {:ok, ms} <- reuse, do: ms)} ms (median of 20)"
        [{:error, e} | _] -> "not possible: #{inspect(e)}"
      end

    fresh =
      for _ <- 1..20 do
        {:ok, store} = Components.Store.new_wasi(wasi())
        {t, {:ok, comp}} = :timer.tc(fn -> Components.Component.new(store, bytes) end)
        {t2, {:ok, _}} = :timer.tc(fn -> Components.Instance.new(store, comp, imports()) end)
        {div(t, 1000), div(t2, 1000)}
      end

    full =
      for _ <- 1..5 do
        {pid, ms} = start(bytes)
        Process.exit(pid, :kill)
        ms
      end

    {pid, _} = start(bytes)
    {:ok, _} = normalize(search(pid, bypass))

    rss_before = vm_rss_kb()
    mem_before = :erlang.memory(:total)

    calls =
      for _ <- 1..20 do
        {t, r} = :timer.tc(fn -> search(pid, bypass) end)
        assert {:ok, {:ok, %{releases: [_, _]}}} = normalize(r)
        div(t, 1000)
      end

    rss_after = vm_rss_kb()
    mem_after = :erlang.memory(:total)

    IO.puts("""
    spike measurements:
      wasm size: #{byte_size(bytes)} bytes
      compile ms (3): #{inspect(compile_ms)} median=#{median(compile_ms)}
      reused-component instantiate: #{reuse_report}
      fresh store+compile (20) ms: median=#{median(Enum.map(fresh, &elem(&1, 0)))}
      fresh store+Instance.new (20) ms: median=#{median(Enum.map(fresh, &elem(&1, 1)))}
      full start_link ms (5): #{inspect(full)} median=#{median(full)}
      search call ms (20): median=#{median(calls)} min=#{Enum.min(calls)} max=#{Enum.max(calls)}
      VmRSS kB before/after 20 calls: #{rss_before} / #{rss_after}
      :erlang.memory(:total) before/after: #{mem_before} / #{mem_after}
    """)

    Process.exit(pid, :kill)
  end

  # Wasmex presents result<T,E> as {:ok, v} | {:error, e}; the outer {:ok, _} is
  # call_function's own wrapper. Records are atom-keyed maps with underscores.
  defp normalize(result), do: result
end
