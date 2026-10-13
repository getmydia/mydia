defmodule Mydia.Indexers.SearchStats.TelemetryTest do
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  alias Mydia.Indexers
  alias Mydia.Indexers.SearchStats.Telemetry

  setup do
    Indexers.register_adapters()
    ref = :telemetry_test.attach_event_handlers(self(), [Telemetry.event()])
    on_exit(fn -> :telemetry.detach(ref) end)
    %{ref: ref}
  end

  defp prowlarr_indexer(name, handler) do
    bypass = Bypass.open()
    Bypass.stub(bypass, "GET", "/api/v1/search", handler)

    indexer_config_fixture(%{
      name: name,
      type: :prowlarr,
      base_url: "http://localhost:#{bypass.port}"
    })
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp item(title) do
    %{
      "title" => title,
      "size" => 1_000_000_000,
      "seeders" => 10,
      "leechers" => 1,
      "magnetUrl" => "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      "indexer" => "upstream"
    }
  end

  defp collect(ref, n) do
    for _ <- 1..n do
      assert_receive {[:mydia, :indexers, :search, :stop], ^ref, measurements, metadata}, 5_000
      {metadata.indexer_name, measurements, metadata}
    end
    |> Map.new(fn {name, m, md} -> {name, {m, md}} end)
  end

  test "one event per indexer: success, adapter error and deadline kill", %{ref: ref} do
    ok =
      prowlarr_indexer("Fictional Good", fn conn ->
        json(conn, 200, [item("Imaginary.Show.S01E01")])
      end)

    bad =
      prowlarr_indexer("Fictional Broken", fn conn -> json(conn, 500, %{"error" => "boom"}) end)

    slow_bypass = Bypass.open()

    Bypass.expect(slow_bypass, "GET", "/api/v1/search", fn conn ->
      # As in the fan-out tests in indexers_test.exs: pass before sleeping so
      # the killed client does not fail Bypass's on_exit verification.
      Bypass.pass(slow_bypass)
      Process.sleep(2_000)
      json(conn, 200, [])
    end)

    slow =
      indexer_config_fixture(%{
        name: "Fictional Slow",
        type: :prowlarr,
        base_url: "http://localhost:#{slow_bypass.port}"
      })

    {:ok, _} =
      Indexers.search_all("Imaginary Show",
        indexer_ids: [ok.id, bad.id, slow.id],
        deadline_ms: 500
      )

    events = collect(ref, 3)

    {m, md} = events["Fictional Good"]
    assert md.kind == :search
    assert md.outcome == :ok
    assert md.indexer_id == ok.id
    assert md.indexer_type == :prowlarr
    assert md.engine == nil
    assert md.error_message == nil
    assert m.result_count == 1
    assert is_integer(m.duration)
    refute Map.has_key?(m, :network)

    {_m, md} = events["Fictional Broken"]
    assert is_atom(md.outcome) and md.outcome not in [:ok, :deadline]
    assert is_binary(md.error_message)

    {_m, md} = events["Fictional Slow"]
    assert md.outcome == :deadline
    assert md.indexer_id == slow.id
  end
end
