defmodule MydiaWeb.PluginSetupLive.ModalTest.HostLive do
  @moduledoc false
  use MydiaWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       slug: session["slug"],
       entry_step: session["step"] || "start",
       instance_id: session["instance_id"],
       closed: nil
     )}
  end

  @impl true
  def handle_info({MydiaWeb.PluginSetupLive.Modal, :closed, info}, socket) do
    {:noreply, assign(socket, closed: info)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p :if={@closed} id="setup-closed-status">{@closed.status}</p>
      <.live_component
        :if={!@closed}
        module={MydiaWeb.PluginSetupLive.Modal}
        id="plugin-setup"
        slug={@slug}
        instance_id={@instance_id}
        entry_step={@entry_step}
        title="Add server"
      />
    </div>
    """
  end
end

defmodule MydiaWeb.PluginSetupLive.ModalTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Mydia.PluginV15Helpers
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Repo
  alias MydiaWeb.PluginSetupLive.Modal
  alias MydiaWeb.PluginSetupLive.ModalTest.HostLive

  setup do
    %{slug: PluginV15Helpers.start_v15_fixture!()}
  end

  defp poll(view) do
    Phoenix.LiveView.send_update(view.pid, Modal, id: "plugin-setup", poll: true)
    render_async(view)
  end

  test "walks sign-in, server choice and account mapping to done", %{conn: conn, slug: slug} do
    user = user_fixture(%{username: "setup_alice"})

    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"slug" => slug})
    render_async(view)

    assert has_element?(view, "#setup-external-auth[phx-hook=ExternalAuthPopup]")

    assert has_element?(
             view,
             "#setup-external-auth-link[href='https://auth.example.invalid/pin']"
           )

    poll(view)
    assert has_element?(view, "#setup-external-auth")
    poll(view)

    view |> element("#setup-option-server-a") |> render_click()
    render_async(view)

    assert has_element?(view, "#setup-mapping-form")
    assert has_element?(view, "#setup-mapping-acct-1")

    view
    |> form("#setup-mapping-form", mapping: %{"acct-1" => user.id, "acct-2" => ""})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#setup-done", "Linked 1 accounts")

    view |> element("#setup-close") |> render_click()
    assert has_element?(view, "#setup-closed-status", "done")

    [instance] = Repo.all(Instance)
    assert instance.enabled
    assert Enum.any?(AccountLinks.list(instance.id), &(&1.user_id == user.id))
  end

  test "renders a form screen and shows host validation errors", %{conn: conn, slug: slug} do
    {:ok, view, _html} =
      live_isolated(conn, HostLive, session: %{"slug" => slug, "step" => "manual-start"})

    render_async(view)
    assert has_element?(view, "#setup-form input[name='setup[url]'][type=url]")
    assert has_element?(view, "#setup-form input[name='setup[token]'][type=password]")

    view |> form("#setup-form", setup: %{"url" => "", "token" => ""}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#plugin-setup-error", "Server URL is required.")

    view
    |> form("#setup-form", setup: %{"url" => "http://10.0.0.9:32400", "token" => "tok"})
    |> render_submit()

    render_async(view)
    assert has_element?(view, "#setup-done", "Manual http://10.0.0.9:32400")
  end

  test "a choice option shows every endpoint it would approve and flags private ones", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"slug" => slug})
    render_async(view)
    poll(view)
    poll(view)

    assert has_element?(
             view,
             "#setup-option-server-a-endpoint-0",
             "http://127.0.0.1:32400"
           )

    assert has_element?(view, "#setup-option-server-a-endpoint-0 .badge", "private network")
  end

  test "a draft that cannot be created shows a readable error", %{conn: conn, slug: slug} do
    config = Mydia.Settings.get_plugin_config_by_slug(slug)
    {:ok, _} = Mydia.Settings.update_plugin_config(config, %{name: String.duplicate("n", 300)})

    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"slug" => slug})
    render_async(view)

    assert has_element?(view, "#plugin-setup-error", "Setup could not start: name")
    refute has_element?(view, "#plugin-setup-error", "Ecto")
    assert has_element?(view, "#setup-cancel")
  end

  test "cancel deletes the draft instance and tells the parent", %{conn: conn, slug: slug} do
    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"slug" => slug})
    render_async(view)
    [draft] = Repo.all(Instance)

    view |> element("#setup-cancel") |> render_click()

    assert has_element?(view, "#setup-closed-status", "cancelled")
    assert Instances.get(draft.id) == nil
  end

  test "cancelling before the first call lands leaves no draft instance", %{
    conn: conn,
    slug: slug
  } do
    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"slug" => slug})

    # Sent while the initial Setup call may still be running; either ordering
    # must end cancelled with the draft removed.
    view |> element("#setup-cancel") |> render_click()
    render_async(view)

    assert has_element?(view, "#setup-closed-status", "cancelled")
    assert Repo.all(Instance) == []
  end

  test "a host validation error keeps what the operator typed", %{conn: conn, slug: slug} do
    {:ok, view, _html} =
      live_isolated(conn, HostLive, session: %{"slug" => slug, "step" => "manual-start"})

    render_async(view)

    view |> form("#setup-form", setup: %{"url" => "", "token" => "keepme"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#plugin-setup-error", "Server URL is required.")
    assert has_element?(view, "#setup-form input[name='setup[token]'][value=keepme]")
  end

  @tag :capture_log
  test "a guest failure on the first step shows the error", %{conn: conn, slug: slug} do
    {:ok, view, _html} =
      live_isolated(conn, HostLive, session: %{"slug" => slug, "step" => "fail"})

    render_async(view)

    assert has_element?(view, "#plugin-setup #plugin-setup-error", "fixture failure")
    assert has_element?(view, "#setup-cancel")
  end

  test "an unknown instance id still renders the modal with an error", %{conn: conn, slug: slug} do
    {:ok, view, _html} =
      live_isolated(conn, HostLive,
        session: %{"slug" => slug, "instance_id" => Ecto.UUID.generate(), "step" => "accounts"}
      )

    assert has_element?(
             view,
             "#plugin-setup #plugin-setup-error",
             "This instance no longer exists."
           )

    view |> element("#setup-cancel") |> render_click()
    assert has_element?(view, "#setup-closed-status", "cancelled")
  end

  test "an existing instance is passed through with its entry step", %{conn: conn, slug: slug} do
    {:ok, instance} = Instances.create(slug, %{name: "Attic", enabled: true})

    {:ok, view, _html} =
      live_isolated(conn, HostLive,
        session: %{"slug" => slug, "instance_id" => instance.id, "step" => "manual-start"}
      )

    render_async(view)
    assert has_element?(view, "#setup-form")

    view |> element("#setup-cancel") |> render_click()
    assert Instances.get(instance.id) != nil
  end

  test "closing the popup triggers an immediate poll", %{conn: conn, slug: slug} do
    {:ok, view, _html} = live_isolated(conn, HostLive, session: %{"slug" => slug})
    render_async(view)

    view |> element("#setup-external-auth") |> render_hook("popup_closed", %{})
    render_async(view)
    poll(view)

    assert has_element?(view, "#setup-option-server-b")
  end
end
