defmodule Mydia.Indexers.CardigannHealthCheckProwlarrTest do
  # Mutates :persistent_term (the active engine), the adapter registry and
  # application env.
  use Mydia.DataCase, async: false

  import Mydia.IndexersFixtures

  alias Mydia.Indexers
  alias Mydia.Indexers.Adapter.{Error, Registry}
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.SearchStats.Telemetry
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  @active_key {Mydia.Indexers.Cardigann.EngineSwitcher, :active}

  setup do
    :persistent_term.put(@active_key, :prowlarr)
    Registry.register(:cardigann, Mydia.Indexers.StubCardigannAdapter)
    Application.put_env(:mydia, :stub_cardigann_pid, self())
    ref = :telemetry_test.attach_event_handlers(self(), [Telemetry.event()])

    on_exit(fn ->
      :persistent_term.erase(@active_key)
      Application.delete_env(:mydia, :stub_cardigann_pid)
      Application.delete_env(:mydia, :stub_cardigann_search)
      Application.delete_env(:mydia, :stub_cardigann_network_us)
      :telemetry.detach(ref)
      Indexers.register_adapters()
    end)

    %{definition: cardigann_definition_fixture(%{enabled: true, type: "public"}), ref: ref}
  end

  defp answer(result), do: Application.put_env(:mydia, :stub_cardigann_search, result)

  defp release do
    %SearchResult{
      title: "Imaginary.Show.S01E01",
      size: 1,
      seeders: 1,
      leechers: 0,
      download_url: "magnet:?xt=urn:btih:fictional",
      indexer: "Fictional Tracker"
    }
  end

  test "probes through the active adapter, not the built-in engine", %{definition: d} do
    answer({:ok, [release()]})

    assert {:ok, %{success: true, status: "healthy"}} = CardigannHealthCheck.test_connection(d.id)
    assert_received {:stub_cardigann_search, query, id}
    assert id == d.id
    assert is_binary(query) and query != ""
    assert Repo.reload!(d).health_status == "healthy"
  end

  test "network time the adapter adds reaches the health event and is taken", %{
    definition: d,
    ref: ref
  } do
    answer({:ok, [release()]})
    Application.put_env(:mydia, :stub_cardigann_network_us, 1_500_000)

    assert {:ok, %{success: true}} = CardigannHealthCheck.test_connection(d.id)

    assert_receive {[:mydia, :indexers, :search, :stop], ^ref, m, %{kind: :health}}
    assert m.network == System.convert_time_unit(1_500, :millisecond, :native)
    assert Mydia.Indexers.SearchStats.Network.take_ms() == nil
  end

  test "zero rows is degraded", %{definition: d} do
    answer({:ok, []})

    assert {:ok, %{success: true, status: "degraded"}} =
             CardigannHealthCheck.test_connection(d.id)
  end

  test "login required reads needs_login and persists nothing", %{definition: d} do
    answer({:error, Error.login_required("Log in first")})
    before = Repo.reload!(d)

    assert {:ok, %{status: "needs_login"}} = CardigannHealthCheck.test_connection(d.id)
    assert Repo.reload!(d).health_status == before.health_status
  end

  test "a Cloudflare failure is degraded, not a failure", %{definition: d} do
    answer({:error, Error.search_failed("FlareSolverr: challenge not solved")})

    assert {:ok, %{success: true, status: "degraded", error: "FlareSolverr:" <> _}} =
             CardigannHealthCheck.test_connection(d.id)
  end

  test "any other error counts a failure", %{definition: d} do
    answer({:error, Error.connection_failed("Connection failed: :nxdomain")})

    assert {:ok, %{success: false, error: "Connection failed: :nxdomain"}} =
             CardigannHealthCheck.test_connection(d.id)
  end

  test "each probe emits a health event tagged with the engine", %{definition: d, ref: ref} do
    answer({:ok, [release()]})
    CardigannHealthCheck.test_connection(d.id)

    assert_receive {[:mydia, :indexers, :search, :stop], ^ref, _m, md}
    assert md.kind == :health
    assert md.outcome == :ok
    assert md.engine == :prowlarr
    assert md.indexer_id == d.id
  end
end
