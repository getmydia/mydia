defmodule Mydia.RequestAccessCatalog do
  @moduledoc """
  A fictional catalog and a four-account cast for the request-access
  end-to-end tests under `test/mydia_web/live/request_access/`.

  A title's rating reaches the app by two paths: Discover visibility reads
  `RemoteSignals` and the trending caches, while request and approval read
  relay metadata. Each title is declared once here and `seed!/0` feeds both
  paths from that one declaration, so the two cannot drift apart and let a
  test pass on inconsistent fixtures.

  Callers must be `async: false`: this swaps `:metadata_relay_url` and writes
  the shared metadata cache.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubs
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers, only: [log_in_user: 2]

  use MydiaWeb, :verified_routes

  alias Mydia.Accounts.Scope
  alias Mydia.Media.ContentRating
  alias Mydia.Media.MediaItem
  alias Mydia.Media.MediaRequest
  alias Mydia.Media.RemoteSignals
  alias Mydia.MediaRequests
  alias Mydia.Repo

  @endpoint MydiaWeb.Endpoint

  alias Mydia.RequestAccessCatalog.Title
  alias Mydia.RequestAccessCatalog.World

  @catalog [
    {:g_movie, "Puddle Lantern", :movie, "G"},
    {:pg_movie, "Maple Orbit", :movie, "PG"},
    {:pg13_movie, "Copper Tide", :movie, "PG-13"},
    {:pg13_shared, "Harbor Kites", :movie, "PG-13"},
    {:r_movie, "Crimson Ledger", :movie, "R"},
    {:unrated_movie, "Fog Archive", :movie, nil},
    {:pg_show, "Tidepool Rangers", :tv_show, "TV-PG"},
    {:ma_show, "Night Ward", :tv_show, "TV-MA"}
  ]

  @doc "The minimum age a title's certification implies; nil when unrated."
  def age(%Title{certification: cert}), do: ContentRating.min_age(cert)

  @doc """
  Seeds every title into both rating paths and points the relay at one Bypass.
  """
  def seed! do
    titles =
      Map.new(@catalog, fn {key, name, type, cert} ->
        {key,
         %Title{
           key: key,
           name: name,
           type: type,
           tmdb_id: unique_provider_id(),
           certification: cert
         }}
      end)

    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])

    for type <- [:movie, :tv_show] do
      rows =
        for {_key, %Title{type: ^type} = t} <- titles do
          name_key = if type == :movie, do: "title", else: "name"
          %{"id" => t.tmdb_id, name_key => t.name}
        end

      warm_trending_cache(type, rows)
    end

    bypass = Bypass.open()

    for {_key, t} <- titles do
      warm_remote_signals({:tmdb, t.tmdb_id}, t.type, %RemoteSignals{
        content_rating: t.certification,
        age: age(t),
        category: to_string(t.type)
      })

      stub = if t.type == :movie, do: &stub_tmdb_movie/3, else: &stub_tmdb_tv/3
      stub.(bypass, t.tmdb_id, title: t.name, certification: t.certification)
    end

    # TV approval from a TMDB ref may look the show up on TVDB; an empty
    # result keeps the TMDB metadata as primary.
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)

    # After the warm_* calls above, which restore the URL they swapped.
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    %World{bypass: bypass, titles: titles}
  end

  @doc """
  Admin, Kid (limit 7), Teen (limit 14; the offered limits are 0, 7, 12, 14, 16, 18, so 13 is
  not allowed) and Adult (no limit), each with a logged-in conn. Also seeds the movie and series library paths approval needs.
  """
  def cast!(conn) do
    library_path_fixture(%{type: "movies"})
    library_path_fixture(%{type: "series"})

    %{
      admin: who(conn, admin_user_fixture()),
      kid: who(conn, restricted_user_fixture(%{role: "guest", max_content_age: 7})),
      teen: who(conn, restricted_user_fixture(%{role: "guest", max_content_age: 14})),
      adult: who(conn, user_fixture(%{role: "guest"}))
    }
  end

  defp who(conn, user), do: %{user: user, conn: log_in_user(conn, user)}

  @doc "Whether `title`'s Discover card is visible to `who`."
  def discover_card?(who, %Title{} = title) do
    {:ok, view, _html} = live(who.conn, discover_path(title))
    has_element?(view, "#discover-grid h3", title.name)
  end

  @doc """
  Clicks Request on the title's Discover card and returns the pending row.
  """
  def request!(who, %Title{} = title) do
    {:ok, view, _html} = live(who.conn, discover_path(title))

    view
    |> element(request_button(title))
    |> render_click()

    assert wait_until(fn -> find_request(title, who.user.id) end),
           "#{title.name} was not requested by #{who.user.username}"

    find_request(title, who.user.id)
  end

  @doc """
  Clicks Request and returns the Discover view without waiting for a row, for
  tests that expect the click to be refused with a flash.
  """
  def click_request(who, %Title{} = title) do
    {:ok, view, _html} = live(who.conn, discover_path(title))
    view |> element(request_button(title)) |> render_click()
    # Sync with the LiveView so the handle_info that submits has run.
    _ = render(view)
    view
  end

  @doc """
  Sends `request_media` for a title with no visible button, as a forged
  client event would, and asserts that no request was created.
  """
  def forge_request(who, %Title{} = title) do
    {:ok, view, _html} = live(who.conn, discover_path(title))

    render_hook(view, "request_media", %{
      "ref" => "tmdb:#{title.tmdb_id}",
      "media_type" => to_string(title.type)
    })

    _ = render(view)
    refute find_request(title, who.user.id), "forged request for #{title.name} was stored"
    :ok
  end

  @doc """
  Files a request through the context with the world's relay config, the
  gate that refuses an above-limit title regardless of the UI.
  """
  def create_as(who, %Title{} = title, %World{bypass: bypass}) do
    MediaRequests.create_request(
      Scope.for_user(who.user),
      %{
        media_type: media_type(title),
        title: title.name,
        tmdb_id: title.tmdb_id,
        requester_id: who.user.id
      },
      config: relay_config(bypass)
    )
  end

  @doc "Approves through `/admin/requests` and returns the reloaded request."
  def approve!(admin, %MediaRequest{} = request) do
    {:ok, view, _html} = live(admin.conn, ~p"/admin/requests")

    view
    |> element(~s(button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"]))
    |> render_click()

    view |> form("#approve-form", approve: %{admin_notes: ""}) |> render_submit()

    approved = Repo.get!(MediaRequest, request.id)
    assert approved.status == "approved", "approval of #{request.title} did not stick"
    refute is_nil(approved.media_item_id), "approval of #{request.title} linked no item"
    approved
  end

  @doc "Rejects through `/admin/requests` and returns the reloaded request."
  def reject!(admin, %MediaRequest{} = request, reason) do
    {:ok, view, _html} = live(admin.conn, ~p"/admin/requests")

    view
    |> element(~s(button[phx-click="open_reject_modal"][phx-value-id="#{request.id}"]))
    |> render_click()

    view |> form("#reject-form", reject: %{rejection_reason: reason}) |> render_submit()

    rejected = Repo.get!(MediaRequest, request.id)
    assert rejected.status == "rejected"
    rejected
  end

  @doc "The `/requests` view for `who`."
  def my_requests_view(who) do
    {:ok, view, _html} = live(who.conn, ~p"/requests")
    view
  end

  @doc "Ids of the request cards on `who`'s `/requests` page."
  def my_request_ids(who) do
    who
    |> my_requests_view()
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='request-']")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "request-", ""))
  end

  @doc """
  Whether `who` can see `title` in the library. Checks the listing and a direct
  `/media/:id` mount and fails if they disagree, so a title that leaks only by
  URL (or only by listing) cannot pass either way.
  """
  def sees_in_library?(who, %Title{} = title) do
    {:ok, view, _html} = live(who.conn, library_path(title))
    _ = render(view)
    listed? = has_element?(view, "#media-items", title.name)

    direct? =
      case media_item_for(title) do
        nil ->
          false

        item ->
          try do
            {:ok, _show, _html} = live(who.conn, ~p"/media/#{item.id}")
            true
          rescue
            Ecto.NoResultsError -> false
          end
      end

    assert listed? == direct?,
           "#{title.name} for #{who.user.username}: listed=#{listed?} but direct=#{direct?}"

    listed?
  end

  def media_item_for(%Title{} = title),
    do: Repo.get_by(MediaItem, type: media_type(title), tmdb_id: title.tmdb_id)

  def find_request(%Title{} = title, requester_id) do
    Repo.get_by(MediaRequest,
      media_type: media_type(title),
      tmdb_id: title.tmdb_id,
      requester_id: requester_id
    )
  end

  def wait_until(fun, retries \\ 200)
  def wait_until(_fun, 0), do: false

  def wait_until(fun, retries) do
    fun.() || (Process.sleep(10) && wait_until(fun, retries - 1))
  end

  defp request_button(%Title{} = t),
    do: ~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{t.tmdb_id}"])

  defp discover_path(%Title{type: :movie}), do: ~p"/discover"
  defp discover_path(%Title{type: :tv_show}), do: ~p"/discover?type=tv_show"

  defp library_path(%Title{type: :movie}), do: ~p"/movies"
  defp library_path(%Title{type: :tv_show}), do: ~p"/tv"

  defp media_type(%Title{type: :movie}), do: "movie"
  defp media_type(%Title{type: :tv_show}), do: "tv_show"
end
