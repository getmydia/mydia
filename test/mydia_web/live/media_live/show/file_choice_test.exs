defmodule MydiaWeb.MediaLive.Show.FileChoiceTest do
  @moduledoc """
  "Choose files…" in the manual-search dialog: list a torrent's files before
  the grab, adjust Mydia's picks in a folder tree and grab only those. rqbit
  runs behind Bypass as a runtime client.

  `async: false`: the runtime config and the "downloads" topic are global.
  """
  use MydiaWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Downloads.{Download, History, Queue}
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.IndexerProgress
  alias Mydia.Repo
  alias MydiaWeb.Live.SearchResultRef

  @hash "0123456789abcdef0123456789abcdef01234567"
  @pack "The.Lantern.Keepers.S01-S02"

  @release %SearchResult{
    title: "The.Lantern.Keepers.S01-S02.1080p.WEB-DL",
    download_url: "magnet:?xt=urn:btih:#{@hash}",
    indexer: "Velvet Lantern",
    size: 300,
    seeders: 12,
    leechers: 1,
    download_protocol: :torrent
  }

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)
    show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers"})
    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
    episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 1})
    Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    %{conn: conn, show: show}
  end

  describe "with rqbit" do
    setup do
      bypass = Bypass.open()
      setup_runtime_config([rqbit_client(bypass.port)])
      # The add first asks whether rqbit already holds the hash; it does not.
      Bypass.stub(bypass, "GET", "/torrents/:id", &Plug.Conn.resp(&1, 404, ""))
      # The page lists the client's torrents for its downloads section.
      Bypass.stub(bypass, "GET", "/torrents", &json_resp(&1, 200, %{"torrents" => []}))
      %{bypass: bypass}
    end

    test "the button shows only when the client can choose files", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view, [@release, nzb_release()])

      assert has_element?(view, "#choose-files-#{SearchResultRef.ref(@release)}")
      refute has_element?(view, "#choose-files-#{SearchResultRef.ref(nzb_release())}")
    end

    test "opening shows the automatic picks ticked", ctx do
      expect_rqbit(ctx.bypass, :ok)
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)

      choose_files(view)
      assert has_element?(view, "#file-choice-modal")
      render_async(view, 2_000)

      assert has_element?(view, "#file-choice-modal #file-choice-tree-file-0[checked]")
      assert has_element?(view, "#file-choice-modal #file-choice-tree-file-1[checked]")
      refute has_element?(view, "#file-choice-modal #file-choice-tree-file-2[checked]")
      assert has_element?(view, "#file-choice-modal", "picked 2 of 3 files")
    end

    test "confirming grabs the chosen files", ctx do
      expect_rqbit(ctx.bypass, :ok)
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)
      choose_files(view)
      render_async(view, 2_000)

      # Untick the first season; the second season's episode stays.
      view
      |> element("#file-choice-tree-folder-#{:erlang.phash2("#{@pack}/Season 01")}")
      |> render_click()

      refute has_element?(view, "#file-choice-tree-file-0[checked]")
      html = view |> element("#file-choice-confirm") |> render_click()

      refute has_element?(view, "#file-choice-modal")
      assert grabbing?(html)

      download = Repo.get_by!(Download, title: @release.title)
      download_id = download.id
      assert_receive {:grab_completed, %{download_id: ^download_id}}, 2_000

      reloaded = Repo.get!(Download, download_id)
      assert reloaded.metadata["selected_files"] == [1]
      assert reloaded.metadata["file_selection"] == %{"source" => "manual"}
      assert_received {:list_only, _}
      assert_received {:add, add_params}
      assert add_params["only_files"] == "1"
    end

    test "confirm is disabled without a video", ctx do
      expect_rqbit(ctx.bypass, :ok)
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)
      choose_files(view)
      render_async(view, 2_000)

      # Clear everything, then tick only the .nfo.
      view |> element("#file-choice-tree-all") |> render_click()
      view |> element("#file-choice-tree-all") |> render_click()
      view |> element("#file-choice-tree-file-2") |> render_click()

      assert has_element?(view, "#file-choice-confirm[disabled]")
      assert has_element?(view, "#file-choice-modal", "Choose at least one video file.")

      # A forged confirm grabs nothing either.
      render_click(view, "confirm_file_choice", %{})
      assert has_element?(view, "#file-choice-modal")
      refute Repo.get_by(Download, title: @release.title)
    end

    test "cancel adds nothing", ctx do
      expect_rqbit(ctx.bypass, :ok)
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)
      choose_files(view)
      render_async(view, 2_000)

      view |> element("#file-choice-cancel") |> render_click()

      refute has_element?(view, "#file-choice-modal")
      assert has_element?(view, "#manual-search-modal")
      assert_received {:list_only, _}
      refute_receive {:add, _}, 200
      refute Repo.get_by(Download, title: @release.title)
    end

    test "a failed preview offers the automatic download", ctx do
      expect_rqbit(ctx.bypass, :error)
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)
      choose_files(view)

      capture_log(fn -> render_async(view, 2_000) end)

      assert has_element?(view, "#file-choice-auto")
      refute has_element?(view, "#file-choice-confirm")

      html = view |> element("#file-choice-auto") |> render_click()

      refute has_element?(view, "#file-choice-modal")
      assert grabbing?(html)
      download = Repo.get_by!(Download, title: @release.title)
      assert download.media_item_id == ctx.show.id

      download_id = download.id

      capture_log(fn ->
        assert_receive {:grab_completed, %{download_id: ^download_id}}, 2_000
      end)
    end

    test "closing during loading ignores the late result", ctx do
      # The listing never answers, so the cancel lands while it is in flight.
      # Not Bypass: it fails the test when the cancel drops the request.
      port = stalling_rqbit(self())
      setup_runtime_config([rqbit_client(port)])

      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)
      choose_files(view)

      assert has_element?(view, "#file-choice-modal")
      assert_receive :listing_started, 1_000

      view |> element("#file-choice-cancel") |> render_click()

      render_async(view, 2_000)
      refute has_element?(view, "#file-choice-modal")
      assert has_element?(view, "#manual-search-modal")
    end

    test "a duplicate found at preview offers no download and marks the row", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)

      {:ok, _other} =
        History.create_download(%{
          indexer: @release.indexer,
          title: @release.title,
          download_url: @release.download_url,
          media_item_id: ctx.show.id,
          metadata: Queue.build_download_metadata(@release)
        })

      choose_files(view)
      capture_log(fn -> render_async(view, 2_000) end)

      assert has_element?(view, "#file-choice-error", "Already downloading")
      refute has_element?(view, "#file-choice-auto")
      refute has_element?(view, "#file-choice-confirm")
      assert has_element?(view, "#file-choice-cancel")
      assert has_element?(view, ~s(#manual-search-results button[title="Already downloading"]))
      refute_received {:list_only, _}

      view |> element("#file-choice-cancel") |> render_click()
      refute has_element?(view, "#file-choice-modal")
      assert has_element?(view, ~s(#manual-search-results button[title="Already downloading"]))
    end

    test "a duplicate found at confirm shows already downloading", ctx do
      expect_rqbit(ctx.bypass, :ok)
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)
      choose_files(view)
      render_async(view, 2_000)

      # Another grab of the same release starts while the dialog is open.
      {:ok, _other} =
        History.create_download(%{
          indexer: @release.indexer,
          title: @release.title,
          download_url: @release.download_url,
          media_item_id: ctx.show.id,
          metadata: Queue.build_download_metadata(@release)
        })

      capture_log(fn ->
        view |> element("#file-choice-confirm") |> render_click()
        assert_receive {:grab_duplicate, %{}}, 2_000
      end)

      render(view)
      assert has_element?(view, ~s(button[title="Already downloading"]))
      refute_received {:add, _}
    end
  end

  describe "without file selection" do
    test "a plain client shows no button", ctx do
      setup_runtime_config([plain_client()])
      {:ok, view, _html} = live(ctx.conn, ~p"/media/#{ctx.show.id}")
      open_with_release(view)

      assert has_element?(view, ~s(button[phx-click="download_from_search"]))
      refute has_element?(view, "#choose-files-#{SearchResultRef.ref(@release)}")
    end
  end

  # -- helpers ------------------------------------------------------------

  # The click's own render: the grab task can finish before a later render
  # would look, turning the row to "Grabbed".
  defp grabbing?(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(#manual-search-results button[title="Grabbing…"]))
    |> Enum.any?()
  end

  defp choose_files(view) do
    view |> element("#choose-files-#{SearchResultRef.ref(@release)}") |> render_click()
  end

  # Opens the dialog (no indexers configured, so the search itself finds
  # nothing) and feeds it the releases the way an indexer's progress would.
  defp open_with_release(view, releases \\ [@release]) do
    render_click(view, "manual_search", %{})
    search_id = :sys.get_state(view.pid).socket.assigns.search_id

    send(
      view.pid,
      {:indexer_progress, search_id,
       %IndexerProgress{
         indexer: "Velvet Lantern",
         indexer_id: "velvet",
         status: :ok,
         results: releases,
         result_count: length(releases),
         duration_ms: 10,
         completed: 1,
         total: 1
       }}
    )

    render(view)
  end

  # A bare rqbit stand-in: the page's torrent list gets an empty answer, and a
  # listing request is reported to the test and then never answered.
  defp stalling_rqbit(test_pid) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = spawn(fn -> accept_loop(listen, test_pid) end)
    :ok = :gen_tcp.controlling_process(listen, server)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp accept_loop(listen, test_pid) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn_link(fn -> serve(socket, test_pid) end)
        :gen_tcp.controlling_process(socket, handler)
        send(handler, :go)
        accept_loop(listen, test_pid)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket, test_pid) do
    receive do
      :go -> :ok
    end

    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, "POST " <> _} ->
        send(test_pid, :listing_started)
        Process.sleep(:infinity)

      {:ok, "GET " <> _} ->
        body = ~s({"torrents":[]})

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
            "content-length: #{byte_size(body)}\r\n\r\n" <> body
        )

        serve_keepalive(socket, test_pid)

      _closed ->
        :ok
    end
  end

  defp serve_keepalive(socket, test_pid) do
    send(self(), :go)
    serve(socket, test_pid)
  end

  defp nzb_release do
    %SearchResult{
      title: "The.Lantern.Keepers.S01.1080p.NZB",
      download_url: "https://usenet.example.test/get/7.nzb",
      indexer: "Velvet Lantern",
      size: 200,
      seeders: nil,
      leechers: nil,
      download_protocol: :nzb
    }
  end

  defp expect_rqbit(bypass, listing) do
    test_pid = self()

    Bypass.expect(bypass, "POST", "/torrents", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      if conn.query_params["list_only"] == "true" do
        send(test_pid, {:list_only, conn.query_params})
        listing_response(conn, listing)
      else
        send(test_pid, {:add, conn.query_params})
        json_resp(conn, 200, %{"id" => 0, "details" => %{"id" => 0, "info_hash" => @hash}})
      end
    end)
  end

  defp listing_response(conn, :ok), do: json_resp(conn, 200, listing_body(files()))

  defp listing_response(conn, :error),
    do: json_resp(conn, 500, %{"error_kind" => "internal_error", "human_readable" => "nope"})

  # Two episodes in season folders and an .nfo Mydia leaves out.
  defp files do
    [
      {"Season 01", "The.Lantern.Keepers.S01E01.1080p.mkv", 100},
      {"Season 02", "The.Lantern.Keepers.S02E01.1080p.mkv", 100},
      {nil, "release.nfo", 1}
    ]
    |> Enum.map(fn
      {nil, name, length} ->
        %{"name" => name, "components" => [@pack, name], "length" => length}

      {folder, name, length} ->
        %{"name" => name, "components" => [@pack, folder, name], "length" => length}
    end)
  end

  defp listing_body(files) do
    %{
      "id" => nil,
      "seen_peers" => ["10.0.0.2:6881"],
      "details" => %{"info_hash" => @hash, "files" => files}
    }
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp rqbit_client(port) do
    %{
      name: "lantern-rqbit",
      type: :rqbit,
      enabled: true,
      host: "localhost",
      port: port,
      use_ssl: false,
      priority: 1,
      connection_settings: %{timeout: 500}
    }
  end

  defp plain_client do
    %{
      name: "lantern-qbit",
      type: :qbittorrent,
      enabled: true,
      host: "localhost",
      port: 1,
      use_ssl: false,
      priority: 1
    }
  end

  # The page reads more of the runtime config than the download clients, so
  # start from a full one.
  defp setup_runtime_config(download_clients) do
    base = Application.get_env(:mydia, :runtime_config) || Mydia.Config.Schema.defaults()
    config = %{base | download_clients: download_clients}

    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end
end
