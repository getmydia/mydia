defmodule Mydia.Indexers.Cardigann.Parity.RunnerTest do
  # Replays a hand-written capture through both engines.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Cardigann.Parity.{Capture, RequestKey, Runner}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

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

  # Divergences the oracle reports for every result of this definition: the wasm
  # engine sets a guid and leaves tmdb_id nil where the native one does the reverse.
  @known_fields [:guid, :tmdb_id]

  @wasm_shaped "search?q=lantern%3Fq%3Dlantern"

  @yaml """
  id: harbor
  name: Harbor
  description: Invented tracker for parity tests
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://harbor.invalid/
    - https://mirror.invalid/
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

  setup do
    :ok = Engine.ensure_started()

    on_exit(fn ->
      Supervisor.terminate_child(Mydia.Supervisor, Engine)
      Supervisor.delete_child(Mydia.Supervisor, Engine)
    end)

    unless Engine.available?() do
      flunk("cardigann.wasm unavailable (#{inspect(Artifact.load())})")
    end

    original = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    on_exit(fn -> Application.put_env(:mydia, :features, original) end)

    assert :ok = Runner.prepare_definition("harbor", @yaml)
    :ok
  end

  defp request(path, host \\ "harbor"),
    do: RequestKey.new("GET", "https://#{host}.invalid/#{path}", nil)

  defp ok(path, body, host),
    do: %Exchange{
      request: request(path, host),
      status: 200,
      headers: [{"content-type", "text/html"}],
      body: body
    }

  defp capture(exchanges),
    do: %Capture{
      definition: "harbor",
      ref: "test",
      query: %{kind: :generic, term: "lantern"},
      exchanges: exchanges
    }

  test "replays a capture through both engines with only the known field divergences" do
    result =
      Runner.replay(
        capture([
          %Exchange{request: request("search?q=lantern"), error: :timeout},
          ok("search?q=lantern", @page, "mirror")
        ])
      )

    assert {:ok, [_, _]} = result.wasm
    assert result.wasm_misses == []
    assert %{divergences: divs, paired: 2} = Runner.compare(result)
    assert {:ok, _} = result.native
    assert MapSet.new(divs, & &1.field) == MapSet.new(@known_fields)
    assert Enum.all?(divs, &(&1.kind == :field))
  end

  test "a changed body that both engines read the same way adds no divergence" do
    page = String.replace(@page, "Lantern Harbor", "Lantern Quay")

    result =
      Runner.replay(
        capture([
          %Exchange{request: request("search?q=lantern"), error: :timeout},
          ok("search?q=lantern", page, "mirror")
        ])
      )

    assert {:ok, results} = result.native
    assert "Lantern Quay 2031 1080p WEB" in Enum.map(results, & &1.title)
    assert %{divergences: divs, paired: 2} = Runner.compare(result)
    assert {:ok, _} = result.native
    assert MapSet.new(divs, & &1.field) == MapSet.new(@known_fields)
    assert Enum.all?(divs, &(&1.kind == :field))
  end

  test "a request only the native engine makes is a real :request divergence" do
    # With the inputs already in the path's query, the guest appends them again
    # while the native engine does not, so the two build different URLs.
    yaml = String.replace(@yaml, "- path: search\n", "- path: search?q={{ .Keywords }}\n")
    assert :ok = Runner.prepare_definition("harbor", yaml)

    result = Runner.replay(capture([ok(@wasm_shaped, @page, "harbor")]))

    assert result.wasm_misses == []
    assert {:ok, [_, _]} = result.wasm
    assert result.misses != []
    assert %{divergences: divs} = Runner.compare(result)
    assert Enum.any?(divs, &(&1.kind == :request))
  end

  test "a wasm miss is a harness bug" do
    result = Runner.replay(capture([]))
    assert result.wasm_misses != []
    assert_raise RuntimeError, ~r/harness bug/, fn -> Runner.compare(result) end
  end
end
