defmodule MydiaWeb.PluginPageLiveTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.Plugins.Grants
  alias Mydia.Plugins.PageActions
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry

  @slug "helper"

  setup %{conn: conn} do
    caps = %{"surfaces:page" => [], "surfaces:write" => ["collections:write"]}

    {:ok, _} =
      Mydia.Settings.create_plugin_config(%{
        slug: @slug,
        name: "Helper",
        version: "0.1.0",
        source_url: "test",
        manifest: %{"slug" => @slug, "name" => "Helper", "version" => "0.1.0"},
        granted_capabilities: caps,
        enabled: true
      })

    plugin = %Plugin{
      slug: @slug,
      name: "Helper",
      enabled: true,
      granted_capabilities: caps,
      page: %{"title" => "Helper", "icon" => "hero-sparkles"}
    }

    Registry.register(@slug, plugin)
    on_exit(fn -> Registry.unregister(@slug) end)

    {conn, user} = register_and_log_in_user(conn)
    {:ok, conn: conn, user: user, plugin: plugin}
  end

  defp pending_write(plugin, user, session_id, name) do
    ctx = %{
      handler: :on_http,
      acting_user_id: user.id,
      role: user.role,
      session_id: session_id,
      invocation_id: "i",
      slug: @slug
    }

    {:ok, {:"needs-confirmation", id}} =
      PageActions.collection_create(plugin, ctx, %{name: {:some, name}})

    id
  end

  defp session_id(view), do: :sys.get_state(view.pid).socket.assigns.session_id

  test "renders a sandboxed, referrer-free iframe with a frame token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    assert has_element?(view, "#plugin-frame[sandbox='allow-scripts allow-forms']")
    assert has_element?(view, "#plugin-frame[referrerpolicy='no-referrer']")

    assert view |> element("#plugin-frame") |> render() =~
             "/plugins/#{@slug}/app/?#{MydiaWeb.PluginFrameToken.param()}="
  end

  test "the navbar lists the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    assert has_element?(view, "#plugin-nav-#{@slug}")
  end

  test "unknown or disabled plugins redirect home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/plugins/nope")
  end

  test "confirming a pending write with Allow for this session", %{
    conn: conn,
    user: user,
    plugin: plugin
  } do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    sid = session_id(view)
    id = pending_write(plugin, user, sid, "Rainy Sundays")

    render_hook(view, "confirm_writes", %{"ids" => [id]})
    assert has_element?(view, "#plugin-confirm-modal")
    assert view |> element("#plugin-confirm-modal") |> render() =~ "Rainy Sundays"

    view |> element("#plugin-confirm-session") |> render_click()
    refute has_element?(view, "#plugin-confirm-modal")
    assert Grants.granted?(@slug, user.id, "collections:write", sid)
    assert_push_event(view, "plugin_frame:post", %{message: %{"mydia" => "confirmed"}})
  end

  test "denying discards the pending write and tells the frame", %{
    conn: conn,
    user: user,
    plugin: plugin
  } do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    sid = session_id(view)
    id = pending_write(plugin, user, sid, "Nope")

    render_hook(view, "confirm_writes", %{"ids" => [id]})
    view |> element("#plugin-confirm-deny") |> render_click()

    refute has_element?(view, "#plugin-confirm-modal")
    assert_push_event(view, "plugin_frame:post", %{message: %{"mydia" => "denied"}})
    assert {:ok, []} = PageActions.pending(@slug, user.id, sid, [])
    refute Grants.granted?(@slug, user.id, "collections:write", sid)
  end

  test "a decide event without an open modal does nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    render_hook(view, "decide", %{"choice" => "always"})
    refute has_element?(view, "#plugin-confirm-modal")
  end

  test "ids from another session never open the modal", %{conn: conn, user: user, plugin: plugin} do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    id = pending_write(plugin, user, "other", "X")

    render_hook(view, "confirm_writes", %{"ids" => [id]})
    refute has_element?(view, "#plugin-confirm-modal")
    assert_push_event(view, "plugin_frame:post", %{message: %{"mydia" => "expired"}})
  end

  test "the frame token is re-minted for the frame before it expires", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/plugins/#{@slug}")
    sid = session_id(view)

    send(view.pid, :refresh_frame_token)

    assert_push_event(view, "plugin_frame:post", %{
      message: %{"mydia" => "token", "token" => token}
    })

    assert {:ok, %{slug: @slug, user_id: user_id, session_id: ^sid}} =
             MydiaWeb.PluginFrameToken.verify(token)

    assert user_id == user.id
  end
end
