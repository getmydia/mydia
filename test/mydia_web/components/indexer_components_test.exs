defmodule MydiaWeb.IndexerComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Indexers.Structs.IndexerProgress

  defp progress_map(entries) do
    Map.new(entries, fn entry -> {entry.indexer_id, entry} end)
  end

  test "renders a row per indexer with a stable DOM id" do
    progress =
      progress_map([
        %IndexerProgress{indexer: "Prowlarr", indexer_id: "a", status: :pending, total: 2},
        %IndexerProgress{
          indexer: "Nyaa",
          indexer_id: "b",
          status: :ok,
          result_count: 12,
          duration_ms: 840,
          total: 2
        }
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: progress)

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-status-a") |> Enum.count() == 1
    assert LazyHTML.query(document, "#indexer-status-b") |> Enum.count() == 1
    assert html =~ "12 results"
  end

  test "a pending indexer shows a spinner and no retry button" do
    progress =
      progress_map([
        %IndexerProgress{indexer: "Prowlarr", indexer_id: "a", status: :pending, total: 1}
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1,
        progress: progress,
        retry_event: "retry_indexer"
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-status-a .loading") |> Enum.count() == 1
    assert LazyHTML.query(document, "#indexer-status-a button") |> Enum.empty?()
  end

  test "a failed indexer shows its error and a retry button when the event is given" do
    progress =
      progress_map([
        %IndexerProgress{
          indexer: "AnimeTosho",
          indexer_id: "c",
          status: :error,
          error: "Connection failed: :econnrefused",
          total: 1
        }
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1,
        progress: progress,
        retry_event: "retry_indexer"
      )

    document = LazyHTML.from_fragment(html)

    assert html =~ "econnrefused"
    assert LazyHTML.query(document, "#indexer-status-c button") |> Enum.count() == 1
  end

  test "a timed-out indexer renders without a retry button when no event is given" do
    progress =
      progress_map([
        %IndexerProgress{
          indexer: "FileList",
          indexer_id: "d",
          status: :timeout,
          error: "Timed out",
          total: 1
        }
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: progress)

    document = LazyHTML.from_fragment(html)

    assert html =~ "timed out"
    assert LazyHTML.query(document, "#indexer-status-d button") |> Enum.empty?()
  end

  test "renders nothing when there is no progress" do
    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: %{})

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status") |> Enum.empty?()
  end
end
