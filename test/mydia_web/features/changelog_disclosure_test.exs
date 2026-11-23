defmodule MydiaWeb.Features.ChangelogDisclosureTest do
  @moduledoc """
  Browser regression for the /changelog disclosures.

  Each release is a `<details>` whose `open` attribute the server renders only
  for unseen versions. The user toggles it natively, so the browser holds the
  real state. Before `JS.ignore_attributes(["open"])`, any later patch (here a
  socket drop and rejoin, which re-renders the whole view) re-applied the
  server's markup: the older release being read snapped shut, and an unseen
  one the user had closed sprang back open.

  A LiveView test cannot see this, because the state lives only in the DOM.
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  alias Mydia.Accounts
  alias Mydia.Changelog
  alias MydiaWeb.ChangelogLive

  @open? """
  const d = document.querySelector('#' + arguments[0] + ' details');
  if (!d) { return 'no details for ' + arguments[0]; }
  return d.open;
  """

  @connected? """
  const main = document.querySelector('[data-phx-main]');
  if (!main) { return 'no main view'; }
  return main.classList.contains('phx-connected');
  """

  @tag :feature
  test "user-toggled releases keep their state across a rejoin", %{session: session} do
    [latest, older | _] = Changelog.entries()

    user = create_admin_user()
    {:ok, _} = Accounts.mark_changelog_seen(user, older.version_string)

    unseen_id = ChangelogLive.Index.entry_id(latest.version_string)
    seen_id = ChangelogLive.Index.entry_id(older.version_string)

    session
    |> login(user.username, "password123")
    |> visit_liveview("/changelog")

    assert eval_js(session, @open?, [unseen_id]) == true
    assert eval_js(session, @open?, [seen_id]) == false

    session
    |> click(Query.css("##{seen_id} summary"))
    |> click(Query.css("##{unseen_id} summary"))

    assert eval_js(session, @open?, [seen_id]) == true
    assert eval_js(session, @open?, [unseen_id]) == false

    rejoin(session)

    assert eval_js(session, @open?, [seen_id]) == true,
           "the release being read was shut by the rejoin patch"

    assert eval_js(session, @open?, [unseen_id]) == false,
           "the unseen release the user closed was reopened by the rejoin patch"
  end

  # Drops the LiveView socket and reconnects it. The rejoin renders the whole
  # view again, the same as a reconnect after a network blip.
  defp rejoin(session) do
    eval_js(session, "liveSocket.disconnect(); return true;")

    eventually(
      fn -> if eval_js(session, @connected?) == false, do: {:ok, :down}, else: :error end,
      description: "the LiveView to disconnect"
    )

    eval_js(session, "liveSocket.connect(); return true;")

    eventually(
      fn -> if eval_js(session, @connected?) == true, do: {:ok, :up}, else: :error end,
      description: "the LiveView to rejoin"
    )

    # The join patch lands with phx-connected; give any trailing patch a beat.
    Process.sleep(300)
  end
end
