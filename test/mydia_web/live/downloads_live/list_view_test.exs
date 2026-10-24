defmodule MydiaWeb.DownloadsLive.ListViewTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Structs.EnrichedDownload
  alias MydiaWeb.DownloadsLive.{Filters, ListView, Summary}

  defp download(attrs) do
    struct!(
      EnrichedDownload,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          title: "Fictional.Salt.Meridian.2031.1080p.WEB",
          status: "downloading",
          download_client: "alpha",
          media_item: %{title: "Fictional Salt Meridian", type: "movie"},
          media_item_id: Ecto.UUID.generate(),
          episode: nil,
          metadata: %{},
          imported_at: nil,
          import_failed_at: nil,
          completed_at: nil,
          stalled_since: nil,
          size: 1_000,
          downloaded: 250,
          download_speed: 100,
          upload_speed: 10,
          eta: 30,
          status_as_of: nil
        },
        attrs
      )
    )
  end

  describe "parse_filters/2" do
    test "trims the query and turns blanks into nil" do
      assert %Filters{q: "salt", client: nil, status: nil} =
               ListView.parse_filters(%{"q" => "  salt ", "client" => ""}, {:downloads, :active})

      assert %Filters{q: nil} = ListView.parse_filters(%{"q" => "   "}, {:downloads, :active})
    end

    test "keeps a valid status in the Active view of the Downloads tab only" do
      assert %Filters{status: "stalled"} =
               ListView.parse_filters(%{"status" => "stalled"}, {:downloads, :active})

      assert %Filters{status: nil} =
               ListView.parse_filters(%{"status" => "stalled"}, {:downloads, :imported})

      assert %Filters{status: nil} =
               ListView.parse_filters(%{"status" => "stalled"}, {:issues, nil})

      assert %Filters{status: nil} =
               ListView.parse_filters(%{"status" => "bogus"}, {:downloads, :active})
    end
  end

  describe "normalize_legacy/1" do
    test "?tab=queue becomes the Downloads tab and keeps the status" do
      assert ListView.normalize_legacy(%{"tab" => "queue", "status" => "paused"}) ==
               %{"status" => "paused"}
    end

    test "?tab=completed becomes the Imported view and drops the status" do
      assert ListView.normalize_legacy(%{"tab" => "completed", "status" => "paused", "q" => "x"}) ==
               %{"view" => "imported", "q" => "x"}
    end

    test "leaves current URLs alone" do
      params = %{"tab" => "issues", "q" => "x"}
      assert ListView.normalize_legacy(params) == params
    end
  end

  describe "parse_tab/1 and parse_view/1" do
    test "unknown or missing values fall back to the defaults" do
      assert ListView.parse_tab("issues") == :issues
      assert ListView.parse_tab("external") == :external
      assert ListView.parse_tab("downloads") == :downloads
      assert ListView.parse_tab("bogus") == :downloads
      assert ListView.parse_tab(nil) == :downloads

      assert ListView.parse_view("imported") == :imported
      assert ListView.parse_view("all") == :all
      assert ListView.parse_view("bogus") == :active
      assert ListView.parse_view(nil) == :active
    end
  end

  describe "rows_for_view/2 and row_kind/1" do
    setup do
      now = DateTime.utc_now()

      %{
        active: download(%{title: "Active.Row", status: "downloading"}),
        imported: download(%{title: "Imported.Row", status: "seeding", imported_at: now}),
        failed: download(%{title: "Failed.Row", status: "failed"})
      }
    end

    test "Active is the in-flight rows, Imported the imported ones, All both", rows do
      all = [rows.active, rows.imported, rows.failed]

      assert ListView.rows_for_view(all, :active) == [rows.active]
      assert ListView.rows_for_view(all, :imported) == [rows.imported]
      assert ListView.rows_for_view(all, :all) == [rows.active, rows.imported]
    end

    test "row_kind follows imported_at, not the page", rows do
      assert ListView.row_kind(rows.active) == :queue
      assert ListView.row_kind(rows.imported) == :completed
    end
  end

  describe "active?/1, to_params/1 and chips/1" do
    test "describe the active filters in a fixed order" do
      filters = %Filters{q: "salt", client: "alpha", status: "paused"}

      assert ListView.active?(filters)
      refute ListView.active?(%Filters{})
      assert ListView.to_params(filters) == [q: "salt", client: "alpha", status: "paused"]
      assert ListView.to_params(%Filters{client: "alpha"}) == [client: "alpha"]

      assert ListView.chips(filters) == [
               {"q", "\"salt\""},
               {"client", "Client: alpha"},
               {"status", "Status: Paused"}
             ]
    end
  end

  describe "filter/2" do
    test "matches the display title or the release title, case-insensitively" do
      by_display = download(%{media_item: %{title: "Fictional Salt Meridian", type: "movie"}})

      by_release =
        download(%{media_item: %{title: "Other", type: "movie"}, title: "Copper.Lantern.S01"})

      miss = download(%{media_item: %{title: "Nothing", type: "movie"}, title: "Nope"})

      assert ListView.filter([by_display, by_release, miss], %Filters{q: "SALT"}) == [by_display]

      assert ListView.filter([by_display, by_release, miss], %Filters{q: "lantern"}) == [
               by_release
             ]
    end

    test "matches the client exactly" do
      alpha = download(%{download_client: "alpha"})
      beta = download(%{download_client: "beta"})

      assert ListView.filter([alpha, beta], %Filters{client: "beta"}) == [beta]
    end

    test "matches the row state and combines with the other filters" do
      paused = download(%{status: "paused", download_client: "alpha"})
      paused_beta = download(%{status: "paused", download_client: "beta"})
      running = download(%{status: "downloading"})

      assert ListView.filter(
               [paused, paused_beta, running],
               %Filters{status: "paused", client: "alpha"}
             ) ==
               [paused]
    end

    test "an empty filter returns the list unchanged" do
      list = [download(%{}), download(%{status: "paused"})]
      assert ListView.filter(list, %Filters{}) == list
    end
  end

  describe "row_state/1" do
    test "classifies each queue phase" do
      stalled = download(%{status: "downloading", stalled_since: DateTime.utc_now()})

      assert ListView.row_state(stalled) == "stalled"
      assert ListView.row_state(download(%{status: "downloading"})) == "downloading"
      assert ListView.row_state(download(%{status: "paused"})) == "paused"
      assert ListView.row_state(download(%{status: "grabbing"})) == "queued"
      assert ListView.row_state(download(%{status: "checking"})) == "queued"
      assert ListView.row_state(download(%{status: "seeding"})) == "importing"

      assert ListView.row_state(download(%{status: "seeding", imported_at: DateTime.utc_now()})) ==
               nil
    end
  end

  describe "filter_scan/2" do
    test "filters client scan entries by title and client name" do
      a = %{title: "Copper.Lantern.S01", client_name: "alpha"}
      b = %{title: "Fictional.Salt.Meridian", client_name: "beta"}

      assert ListView.filter_scan([a, b], %Filters{q: "copper"}) == [a]
      assert ListView.filter_scan([a, b], %Filters{client: "beta"}) == [b]
    end
  end

  describe "summarize/1" do
    test "totals speeds and remaining bytes and takes the longest ETA" do
      as_of = ~U[2026-10-16 10:00:00Z]

      list = [
        download(%{download_speed: 100, upload_speed: 5, size: 1_000, downloaded: 400, eta: 30}),
        download(%{
          download_speed: 50,
          upload_speed: nil,
          size: 500,
          downloaded: nil,
          eta: 90,
          status_as_of: as_of
        }),
        download(%{
          status: "downloading",
          stalled_since: DateTime.utc_now(),
          download_speed: nil,
          upload_speed: nil,
          size: nil,
          eta: nil
        })
      ]

      assert %Summary{
               active: 3,
               stalled: 1,
               download_speed: 150,
               upload_speed: 5,
               remaining_bytes: 1_100,
               eta_seconds: 90,
               stale_as_of: ^as_of
             } = ListView.summarize(list)
    end

    test "ignores ETAs on rows that are not downloading" do
      assert %Summary{eta_seconds: nil} =
               ListView.summarize([download(%{status: "seeding", eta: 8_640_000})])
    end

    test "an empty list is all zeros" do
      assert ListView.summarize([]) == %Summary{}
    end
  end

  describe "clients/1, media_item_id/1 and display_title/1" do
    test "lists distinct sorted client names" do
      list = [
        download(%{download_client: "beta"}),
        download(%{download_client: "alpha"}),
        download(%{download_client: nil}),
        download(%{download_client: "beta"})
      ]

      assert ListView.clients(list) == ["alpha", "beta"]
    end

    test "resolves the media item through the episode when the row has none" do
      show_id = Ecto.UUID.generate()

      episode_row =
        download(%{
          media_item_id: nil,
          media_item: nil,
          episode: %{media_item_id: show_id, media_item: %{title: "Copper Lantern"}}
        })

      assert ListView.media_item_id(episode_row) == show_id
      assert ListView.display_title(episode_row) == "Copper Lantern"
      assert ListView.media_item_id(download(%{media_item_id: nil, media_item: nil})) == nil
    end
  end

  describe "kind filter" do
    test "kind is parsed only on the Issues tab" do
      assert ListView.parse_filters(%{"kind" => "missing"}, {:issues, :active}).kind == :missing
      assert ListView.parse_filters(%{"kind" => "missing"}, {:downloads, :active}).kind == nil
      assert ListView.parse_filters(%{"kind" => "nope"}, {:issues, :active}).kind == nil
    end

    test "kind has a chip and a param" do
      filters = %Filters{kind: :import_failed}
      assert {"kind", "Kind: Import failed"} in ListView.chips(filters)
      assert ListView.to_params(filters) == [kind: :import_failed]
    end
  end
end
