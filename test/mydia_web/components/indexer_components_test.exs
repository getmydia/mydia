defmodule MydiaWeb.IndexerComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Indexers.Structs.PausedIndexer
  alias MydiaWeb.IndexerComponents

  defp progress_map(entries) do
    Map.new(entries, fn entry -> {entry.indexer_id, entry} end)
  end

  test "summary shows total results, completion, and hides the detail by default" do
    progress = %{
      "a" => %IndexerProgress{
        indexer_id: "a",
        indexer: "Alpha",
        status: :ok,
        result_count: 5,
        duration_ms: 400
      },
      "b" => %IndexerProgress{indexer_id: "b", indexer: "Beta", status: :pending},
      "c" => %IndexerProgress{indexer_id: "c", indexer: "Gamma", status: :error, error: "boom"}
    }

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1,
        progress: progress,
        retry_event: "retry_indexer"
      )

    assert html =~ "5 results · 2/3 indexers"
    assert html =~ "2/3 indexers"
    assert html =~ "1 failed"

    # The detail list is collapsed by default: <details> has no `open` attribute.
    document = LazyHTML.from_fragment(html)
    assert LazyHTML.query(document, "details[open]") |> Enum.empty?()
  end

  test "failed row renders a retry button with the indexer id" do
    progress = %{
      "c" => %IndexerProgress{indexer_id: "c", indexer: "Gamma", status: :error, error: "boom"}
    }

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1,
        progress: progress,
        retry_event: "retry_indexer"
      )

    assert html =~ ~s(phx-click="retry_indexer")
    assert html =~ ~s(phx-value-id="c")
  end

  test "renders nothing when there is no progress" do
    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: %{})

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status") |> Enum.empty?()
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

    assert LazyHTML.query(document, "#indexer-search-status ul li .loading") |> Enum.count() == 1
    assert LazyHTML.query(document, "#indexer-search-status button") |> Enum.empty?()
  end

  test "the summary spins and shows a determinate progress bar while indexers are outstanding" do
    progress =
      progress_map([
        %IndexerProgress{
          indexer: "Alpha",
          indexer_id: "a",
          status: :ok,
          result_count: 5,
          duration_ms: 400,
          total: 3
        },
        %IndexerProgress{indexer: "Beta", indexer_id: "b", status: :pending, total: 3},
        %IndexerProgress{
          indexer: "Gamma",
          indexer_id: "c",
          status: :error,
          error: "boom",
          total: 3
        }
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: progress)

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status summary .loading-spinner")
           |> Enum.count() == 1

    bar = LazyHTML.query(document, "#indexer-search-status summary progress")

    assert LazyHTML.attribute(bar, "value") == ["2"]
    assert LazyHTML.attribute(bar, "max") == ["3"]

    # The success check belongs to the settled state, not this one.
    assert LazyHTML.query(document, "#indexer-search-status summary .hero-check-circle")
           |> Enum.empty?()

    assert LazyHTML.query(document, "#indexer-search-status")
           |> LazyHTML.attribute("aria-busy") == ["true"]
  end

  test "the summary drops the spinner and progress bar once every indexer settles" do
    progress =
      progress_map([
        %IndexerProgress{
          indexer: "Alpha",
          indexer_id: "a",
          status: :ok,
          result_count: 5,
          duration_ms: 400,
          total: 3
        },
        %IndexerProgress{
          indexer: "Beta",
          indexer_id: "b",
          status: :timeout,
          error: "Timed out",
          total: 3
        },
        %IndexerProgress{
          indexer: "Gamma",
          indexer_id: "c",
          status: :error,
          error: "boom",
          total: 3
        }
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: progress)

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status summary .loading") |> Enum.empty?()
    assert LazyHTML.query(document, "#indexer-search-status summary progress") |> Enum.empty?()

    assert LazyHTML.query(document, "#indexer-search-status summary .hero-check-circle")
           |> Enum.count() == 1

    assert LazyHTML.query(document, "#indexer-search-status")
           |> LazyHTML.attribute("aria-busy") == ["false"]
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

    assert html =~ "econnrefused"

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status button") |> Enum.count() == 1

    assert LazyHTML.query(document, "#indexer-search-status button")
           |> LazyHTML.attribute("phx-value-id") ==
             ["c"]
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

    assert html =~ "timed out"

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status button") |> Enum.empty?()
  end

  test "rows render in alphabetical order by indexer name, regardless of status or map order" do
    progress =
      progress_map([
        %IndexerProgress{
          indexer: "Zeta",
          indexer_id: "z",
          status: :error,
          error: "boom",
          total: 3
        },
        %IndexerProgress{
          indexer: "Alpha",
          indexer_id: "a",
          status: :ok,
          result_count: 1,
          duration_ms: 10,
          total: 3
        },
        %IndexerProgress{indexer: "Mango", indexer_id: "m", status: :pending, total: 3}
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1, progress: progress)

    document = LazyHTML.from_fragment(html)

    names =
      document
      |> LazyHTML.query("#indexer-search-status ul li .font-medium")
      |> LazyHTML.text(separator: ",")

    assert names == "Alpha,Mango,Zeta"
  end

  test "a timed-out indexer shows a retry button when the event is given" do
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
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1,
        progress: progress,
        retry_event: "retry_indexer"
      )

    document = LazyHTML.from_fragment(html)

    buttons = LazyHTML.query(document, "#indexer-search-status button")

    assert LazyHTML.attribute(buttons, "phx-value-id") == ["d"]
  end

  test "an ok indexer shows no retry button even when the event is given" do
    progress =
      progress_map([
        %IndexerProgress{
          indexer: "Nyaa",
          indexer_id: "b",
          status: :ok,
          result_count: 12,
          duration_ms: 840,
          total: 1
        }
      ])

    html =
      render_component(&MydiaWeb.IndexerComponents.indexer_search_status/1,
        progress: progress,
        retry_event: "retry_indexer"
      )

    document = LazyHTML.from_fragment(html)

    assert LazyHTML.query(document, "#indexer-search-status button") |> Enum.empty?()
  end

  defp paused(name, seconds) do
    %PausedIndexer{
      id: :erlang.phash2(name),
      name: name,
      disabled_till: DateTime.add(DateTime.utc_now(), seconds, :second)
    }
  end

  describe "paused Prowlarr indexers" do
    test "paused_remaining/2 rounds down to the largest unit" do
      now = ~U[2030-01-01 00:00:00Z]
      assert IndexerComponents.paused_remaining(~U[2030-01-01 00:00:30Z], now) == "<1m"
      assert IndexerComponents.paused_remaining(~U[2030-01-01 00:12:59Z], now) == "12m"
      assert IndexerComponents.paused_remaining(~U[2030-01-01 03:30:00Z], now) == "3h"
      assert IndexerComponents.paused_remaining(~U[2030-01-02 01:00:00Z], now) == "1d"
    end

    test "active_paused/2 drops pauses that have already lapsed" do
      now = ~U[2030-01-01 00:00:00Z]

      live = %PausedIndexer{id: 1, name: "Live", disabled_till: ~U[2030-01-01 00:10:00Z]}
      over = %PausedIndexer{id: 2, name: "Over", disabled_till: ~U[2029-12-31 23:59:00Z]}
      edge = %PausedIndexer{id: 3, name: "Edge", disabled_till: now}

      assert IndexerComponents.active_paused([live, over, edge], now) == [live]
    end

    test "paused_heading/1 pluralizes" do
      assert IndexerComponents.paused_heading(1) == "1 indexer paused by Prowlarr"
      assert IndexerComponents.paused_heading(2) == "2 indexers paused by Prowlarr"
    end

    test "retest_flash/1 summarizes outcomes" do
      amber = paused("Amber Tracker", 600)
      birch = paused("Birch Tracker", 600)

      assert {:info, "Amber Tracker recovered"} =
               IndexerComponents.retest_flash({:ok, %{outcomes: [{amber, :ok}], paused: []}})

      assert {:error, "Amber Tracker recovered. Birch Tracker still failing: Unable to connect"} =
               IndexerComponents.retest_flash(
                 {:ok,
                  %{
                    outcomes: [{amber, :ok}, {birch, {:error, "Unable to connect"}}],
                    paused: [birch]
                  }}
               )

      assert {:info, "No paused indexers to retest"} =
               IndexerComponents.retest_flash({:ok, %{outcomes: [], paused: []}})

      assert {:error, "Retest failed: Indexer not found"} =
               IndexerComponents.retest_flash({:error, "Indexer not found"})
    end

    test "a settled row with paused indexers shows the hint, count and retest button" do
      progress = %{
        "p" => %IndexerProgress{
          indexer_id: "p",
          indexer: "Prowlarr",
          status: :ok,
          result_count: 3,
          duration_ms: 200,
          paused: [paused("Amber Tracker", 600), paused("Birch Tracker", 7_200)]
        }
      }

      html =
        render_component(&IndexerComponents.indexer_search_status/1,
          progress: progress,
          retest_paused_event: "retest_paused"
        )

      document = LazyHTML.from_fragment(html)

      hint = LazyHTML.query(document, "#indexer-paused-p")
      refute Enum.empty?(hint)
      assert LazyHTML.text(hint) =~ "Amber Tracker"
      assert LazyHTML.text(hint) =~ "Birch Tracker"

      assert LazyHTML.text(LazyHTML.query(document, "#indexer-search-paused-count")) =~
               "2 paused"

      button = LazyHTML.query(document, "#indexer-retest-paused-p")
      assert LazyHTML.attribute(button, "phx-click") == ["retest_paused"]
      assert LazyHTML.attribute(button, "phx-value-id") == ["p"]
    end

    test "no hint, count or button when nothing is paused" do
      progress = %{
        "p" => %IndexerProgress{
          indexer_id: "p",
          indexer: "Prowlarr",
          status: :ok,
          result_count: 3
        }
      }

      html =
        render_component(&IndexerComponents.indexer_search_status/1,
          progress: progress,
          retest_paused_event: "retest_paused"
        )

      document = LazyHTML.from_fragment(html)
      assert Enum.empty?(LazyHTML.query(document, "#indexer-paused-p"))
      assert Enum.empty?(LazyHTML.query(document, "#indexer-search-paused-count"))
      assert Enum.empty?(LazyHTML.query(document, "#indexer-retest-paused-p"))
    end
  end
end
