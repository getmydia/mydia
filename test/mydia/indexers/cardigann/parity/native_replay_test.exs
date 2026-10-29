defmodule Mydia.Indexers.Cardigann.Parity.NativeReplayTest do
  # Drives the native Elixir engine from a recorded capture; no network, no Bypass.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Adapter.Cardigann, as: ElixirAdapter
  alias Mydia.Indexers.Cardigann.Parity.{Capture, Replay, RequestKey, Seam}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  @page """
  <html><body><table>
  <tr class="row"><td class="t"><a href="/t/1">Lantern Harbor 2031 1080p WEB</a></td>
  <td class="d"><a href="/dl/1.torrent">dl</a></td><td class="s">1.5 GB</td><td class="se">42</td></tr>
  <tr class="row"><td class="t"><a href="/t/2">Quiet Orchard S01E02 720p HDTV</a></td>
  <td class="d"><a href="/dl/2.torrent">dl</a></td><td class="s">700 MB</td><td class="se">7</td></tr>
  </table></body></html>
  """

  setup do
    original = Application.get_env(:mydia, :features, [])
    Application.put_env(:mydia, :features, cardigann_enabled: true)
    on_exit(fn -> Application.put_env(:mydia, :features, original) end)
    :ok
  end

  defp yaml(paths, extra \\ "") do
    path_lines = Enum.map_join(paths, "\n", &"    - path: #{&1}")

    """
    id: harbor
    name: Harbor
    description: Invented tracker for parity tests
    language: en-US
    type: public
    encoding: UTF-8
    links:
      - https://harbor.invalid/
    #{extra}
    caps:
      categorymappings:
        - {id: 1, cat: Movies, desc: Movies}
      modes:
        search: [q]
    settings: []
    search:
      paths:
    #{path_lines}
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

  defp insert_definition(yaml) do
    {:ok, definition} =
      %CardigannDefinition{}
      |> CardigannDefinition.changeset(%{
        indexer_id: "harbor",
        name: "Harbor",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: %{"0" => "https://harbor.invalid/"},
        capabilities: %{},
        definition: yaml,
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

  defp key(path), do: RequestKey.new("GET", "https://harbor.invalid/#{path}", nil)

  defp capture(exchanges) do
    %Capture{
      definition: "harbor",
      ref: "test",
      query: %{kind: :generic, term: "lantern"},
      exchanges: exchanges
    }
  end

  defp html(path, body),
    do: %Exchange{
      request: key(path),
      status: 200,
      headers: [{"content-type", "text/html"}],
      body: body
    }

  test "replays a recorded search through the native engine" do
    definition = insert_definition(yaml(["search?q={{ .Keywords }}"]))
    {:ok, replay} = Replay.start_link(capture([html("search?q=lantern", @page)]))

    result =
      Seam.with(%{replay: replay}, fn ->
        ElixirAdapter.search(config(definition), "lantern", [])
      end)

    assert {:ok, [%SearchResult{title: "Lantern Harbor 2031 1080p WEB"} | _]} = result
    assert Replay.misses(replay) == []
  end

  test "a request missing from the capture is recorded and does not raise" do
    definition = insert_definition(yaml(["search?q={{ .Keywords }}"]))
    {:ok, replay} = Replay.start_link(capture([]))

    Seam.with(%{replay: replay}, fn -> ElixirAdapter.search(config(definition), "lantern", []) end)

    assert Replay.misses(replay) == [key("search?q=lantern")]
  end

  test "requestDelay does not sleep under replay" do
    definition =
      insert_definition(
        yaml(["search?q={{ .Keywords }}", "find?q={{ .Keywords }}"], "requestDelay: 5")
      )

    # Its own links too: the engine merges rows that share a download link.
    later =
      @page
      |> String.replace("Quiet Orchard S01E02 720p HDTV", "Velvet Weir S02E05 1080p WEB")
      |> String.replace(["/t/2", "/dl/2.torrent"], &String.replace(&1, "2", "3"))

    {:ok, replay} =
      Replay.start_link(capture([html("search?q=lantern", @page), html("find?q=lantern", later)]))

    {elapsed_us, result} =
      :timer.tc(fn ->
        Seam.with(%{replay: replay}, fn ->
          ElixirAdapter.search(config(definition), "lantern", [])
        end)
      end)

    # The second path was searched, not skipped, so its delay was really owed.
    assert {:ok, results} = result
    assert Enum.any?(results, &(&1.title == "Velvet Weir S02E05 1080p WEB"))
    assert Replay.misses(replay) == []
    assert elapsed_us < 2_000_000
  end
end
