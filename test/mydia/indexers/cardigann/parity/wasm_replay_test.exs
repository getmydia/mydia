defmodule Mydia.Indexers.Cardigann.Parity.WasmReplayTest do
  # Drives the wasm engine from a recorded capture, and records a live exchange.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Cardigann.Parity.{Capture, Recorder, Replay, RequestKey, Seam}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Wasm.{Adapter, Artifact, Engine}
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  @moduletag :cardigann_wasm
  @moduletag timeout: 120_000

  @page """
  <html><body><table>
  <tr class="row"><td class="t"><a href="/t/1">Lantern Harbor 2031 1080p WEB</a></td>
  <td class="d"><a href="/dl/1.torrent">dl</a></td><td class="s">1.5 GB</td><td class="se">42</td></tr>
  <tr class="row"><td class="t"><a href="/t/2">Quiet Orchard S01E02 720p HDTV</a></td>
  <td class="d"><a href="/dl/2.torrent">dl</a></td><td class="s">700 MB</td><td class="se">7</td></tr>
  </table></body></html>
  """

  setup do
    :ok = Engine.ensure_started()

    on_exit(fn ->
      Supervisor.terminate_child(Mydia.Supervisor, Engine)
      Supervisor.delete_child(Mydia.Supervisor, Engine)
    end)

    unless Engine.available?() do
      flunk(
        "cardigann.wasm unavailable (#{inspect(Artifact.load())}): " <>
          "run mix mydia.cardigann_guest fetch or native/cardigann_guest/build.sh wasm"
      )
    end

    original_features = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    Application.put_env(:mydia, :cardigann_wasm_gate_opts, allow_private_except_link_local: true)

    on_exit(fn ->
      Application.put_env(:mydia, :features, original_features)
      Application.delete_env(:mydia, :cardigann_wasm_gate_opts)
    end)

    :ok
  end

  # The guest appends the inputs to the path's query itself, so the path stays bare.
  defp yaml(base) do
    """
    id: harbor
    name: Harbor
    description: Invented tracker for parity tests
    language: en-US
    type: public
    encoding: UTF-8
    links:
      - #{base}
    caps:
      categorymappings:
        - {id: 1, cat: Movies, desc: Movies}
      modes:
        search: [q]
    settings: []
    search:
      paths:
        - path: search
      inputs:
        q: "{{ .Keywords }}"
      rows:
        selector: tr.row
      fields:
        title:
          selector: td.t a
        details:
          selector: td.t a
          attribute: href
        download:
          selector: td.d a
          attribute: href
        category:
          text: "1"
        size:
          selector: td.s
        seeders:
          selector: td.se
    """
  end

  defp insert_definition(base) do
    {:ok, definition} =
      %CardigannDefinition{}
      |> CardigannDefinition.changeset(%{
        indexer_id: "harbor",
        name: "Harbor",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: %{"0" => base},
        capabilities: %{},
        definition: yaml(base),
        schema_version: "v11",
        enabled: true,
        in_library: true,
        last_synced_at: DateTime.utc_now()
      })
      |> Repo.insert()

    definition
  end

  defp config(definition) do
    %{
      type: :cardigann,
      name: definition.name,
      indexer_id: definition.indexer_id,
      enabled: true,
      user_settings: %{}
    }
  end

  test "replays a recorded search through the wasm engine" do
    definition = insert_definition("https://harbor.invalid/")

    capture = %Capture{
      definition: "harbor",
      ref: "test",
      query: %{kind: :generic, term: "lantern"},
      exchanges: [
        %Exchange{
          request: RequestKey.new("GET", "https://harbor.invalid/search?q=lantern", nil),
          status: 200,
          headers: [{"content-type", "text/html"}],
          body: @page
        }
      ]
    }

    {:ok, replay} = Replay.start_link(capture)

    result =
      Seam.with(%{replay: replay}, fn -> Adapter.search(config(definition), "lantern", []) end)

    assert {:ok, results} = result

    assert results |> Enum.map(& &1.title) |> Enum.sort() ==
             ["Lantern Harbor 2031 1080p WEB", "Quiet Orchard S01E02 720p HDTV"]

    assert Enum.all?(results, &match?(%SearchResult{}, &1))
    assert Replay.misses(replay) == []
  end

  test "a recorded timeout replays as an error result without raising" do
    definition = insert_definition("https://harbor.invalid/")

    capture = %Capture{
      definition: "harbor",
      ref: "test",
      query: %{kind: :generic, term: "lantern"},
      exchanges: [
        %Exchange{
          request: RequestKey.new("GET", "https://harbor.invalid/search?q=lantern", nil),
          error: :timeout
        }
      ]
    }

    {:ok, replay} = Replay.start_link(capture)

    result =
      Seam.with(%{replay: replay}, fn -> Adapter.search(config(definition), "lantern", []) end)

    assert match?({:error, _}, result) or result == {:ok, []}
    assert Replay.misses(replay) == []
  end

  test "records the exchange a live search makes, without cookie values" do
    bypass = Bypass.open()
    definition = insert_definition("http://localhost:#{bypass.port}/")

    Bypass.stub(bypass, "GET", "/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "sid=s3cret; Path=/")
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.resp(200, @page)
    end)

    {:ok, recorder} = Recorder.start_link()

    {:ok, [_, _]} =
      Seam.with(%{record: recorder}, fn -> Adapter.search(config(definition), "lantern", []) end)

    assert [%Exchange{status: 200, body: body} = ex] = Recorder.exchanges(recorder)
    assert body == @page
    assert ex.request.method == "GET"
    assert {"set-cookie", "<redacted>"} in ex.headers
    refute inspect(ex) =~ "s3cret"
  end
end
