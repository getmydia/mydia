defmodule MydiaWeb.MediaLive.Show.DownloadComponentsTest do
  use MydiaWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias MydiaWeb.MediaLive.Show.{DownloadComponents, DownloadSummary, SeasonComponents}

  defp download(attrs) do
    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        title: "Lantern.Hollow.S02E04.1080p",
        status: "downloading",
        progress: 42.0,
        size: 1_000,
        eta: nil,
        episode_id: nil,
        episode: nil,
        metadata: %{}
      },
      attrs
    )
  end

  defp episode(id, season, number, files \\ []) do
    %Episode{
      id: id,
      season_number: season,
      episode_number: number,
      air_date: ~D[2024-01-01],
      monitored: true,
      media_files: files,
      downloads: []
    }
  end

  defp render_banner(media_item, downloads) do
    render_component(&DownloadComponents.active_download_banner/1,
      media_item: media_item,
      summary: DownloadSummary.build(downloads, media_item.episodes)
    )
    |> LazyHTML.from_fragment()
  end

  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  describe "active_download_banner/1" do
    test "names the episodes and season packs a show is downloading" do
      show = %MediaItem{
        type: "tv_show",
        episodes: [episode("e1", 2, 4), episode("e2", 2, 5), episode("e3", 3, 1)]
      }

      doc =
        render_banner(show, [
          download(%{episode_id: "e2"}),
          download(%{episode_id: "e1"}),
          download(%{metadata: %{"season_pack" => true, "season_number" => 3}})
        ])

      assert text(doc, "#active-download-heading") =~ "Downloading 3 episodes"
      items = text(doc, "#active-download-items")
      assert items =~ ~r/S02E04.*S02E05.*Season 3/s
      assert text(doc, "#active-download-progress") =~ "42%"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#active-download-link"), "href") == [
               "/downloads"
             ]
    end

    test "collapses labels past six into a count" do
      episodes = for n <- 1..8, do: episode("e#{n}", 1, n)
      show = %MediaItem{type: "tv_show", episodes: episodes}
      doc = render_banner(show, for(n <- 1..8, do: download(%{episode_id: "e#{n}"})))

      assert text(doc, "#active-download-items") =~ "+2 more"
    end

    test "badges a state every download shares" do
      show = %MediaItem{type: "tv_show", episodes: [episode("e1", 1, 1)]}
      doc = render_banner(show, [download(%{episode_id: "e1", status: "paused"})])

      assert text(doc, "#active-download-state") =~ "Paused"
    end

    test "shows a movie's release title" do
      movie = %MediaItem{type: "movie", episodes: []}
      doc = render_banner(movie, [download(%{title: "Quiet.Orchard.2031.2160p"})])

      assert text(doc, "#active-download-heading") == "Downloading"
      assert text(doc, "#active-download-alert") =~ "Quiet.Orchard.2031.2160p"
    end

    test "renders nothing when nothing is active" do
      show = %MediaItem{type: "tv_show", episodes: []}
      doc = render_banner(show, [download(%{status: "seeding"})])

      assert LazyHTML.query(doc, "#active-download-alert") |> Enum.empty?()
    end
  end

  describe "season_header/1 with a season pack downloading" do
    test "counts pack-covered episodes as downloading, not missing" do
      episodes = [
        episode("e1", 1, 1, [%MediaFile{id: "f1", size: 1}]),
        episode("e2", 1, 2),
        episode("e3", 1, 3)
      ]

      pack = download(%{metadata: %{"season_pack" => true, "season_number" => 1}})

      doc =
        render_component(&SeasonComponents.season_header/1,
          season_number: 1,
          episodes: episodes,
          download_summary: DownloadSummary.build([pack], episodes),
          expanded?: false
        )
        |> LazyHTML.from_fragment()

      assert text(doc, "#season-1-downloading") =~ "2 downloading"
      refute LazyHTML.text(doc) =~ "missing"
    end
  end
end
