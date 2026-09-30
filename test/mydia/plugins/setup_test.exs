defmodule Mydia.Plugins.SetupTest do
  # async: false: starts a real pool under the app-wide PoolRegistry.
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.AccountsFixtures

  alias Mydia.PluginV14Helpers
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Setup
  alias Mydia.Plugins.Setup.Session

  setup do
    %{slug: PluginV14Helpers.start_v14_fixture!()}
  end

  defp poll_until_choice(session) do
    {:ok, session} = Setup.poll(session)
    {:ok, session} = Setup.poll(session)
    session
  end

  describe "start/3" do
    test "creates a disabled draft instance and shows the first screen", %{slug: slug} do
      assert {:ok, %Session{} = session} = Setup.start(slug, nil, name: "Den")

      assert session.new_instance?
      assert session.status == :active
      assert session.step == "auth"
      assert {:external_auth, %{url: "https://auth.example.invalid/pin"}} = session.screen.body

      instance = Instances.get!(session.instance_id)
      assert instance.name == "Den"
      refute instance.enabled
    end

    test "reuses an existing instance and starts at the requested step", %{slug: slug} do
      {:ok, instance} = Instances.create(slug, %{name: "Attic", enabled: true})

      assert {:ok, session} = Setup.start(slug, instance, step: "manual-start")

      refute session.new_instance?
      assert session.instance_id == instance.id
      assert {:form, %{fields: [%{key: "url"}, %{key: "token"}]}} = session.screen.body
    end

    test "a guest failure lands in session.error", %{slug: slug} do
      log =
        capture_log(fn ->
          assert {:ok, session} = Setup.start(slug, nil, step: "fail")

          assert session.screen == nil
          assert session.error =~ "fixture failure"
        end)

      assert log =~ "setup step fail failed: guest_error"
      refute log =~ "fixture failure"
    end
  end

  describe "the sign-in flow" do
    test "polls, picks a server, maps accounts and enables the instance", %{slug: slug} do
      user = user_fixture()
      {:ok, session} = Setup.start(slug, nil)

      {:ok, session} = Setup.poll(session)
      assert {:external_auth, _} = session.screen.body
      assert session.state_json == ~s({"polls":1})

      {:ok, session} = Setup.poll(session)
      assert {:choice, %{options: [%{id: "server-a"}, %{id: "server-b"}]}} = session.screen.body

      # Top-level credentials arrive with the screen.
      assert AccountLinks.credential(session.instance_id, :owner).access_token == "owner-token"

      {:ok, session} = Setup.advance(session, %{"option_id" => "server-a"})
      assert {:mapping, %{accounts: [_, _]}} = session.screen.body

      instance = Instances.get!(session.instance_id)

      assert instance.approved_endpoints == [
               %{"scheme" => "http", "host" => "127.0.0.1", "port" => 32400}
             ]

      assert AccountLinks.credential(instance.id, :endpoint).access_token == "endpoint-token-a"

      {:ok, session} =
        Setup.advance(session, %{"mapping" => %{"acct-1" => user.id, "acct-2" => ""}})

      assert session.status == :done
      assert {:done, "Linked 1 accounts"} = session.screen.body
      assert Instances.get!(session.instance_id).enabled

      assert [link] =
               session.instance_id
               |> AccountLinks.list()
               |> Enum.filter(&(&1.role == :user))

      assert link.user_id == user.id
      assert link.external_user_id == "acct-1"
      assert link.external_username == "Remote Alice"
      assert link.source == :admin_mapped
    end

    test "the session holds no persisted credential and does not inspect tokens", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil)
      session = poll_until_choice(session)

      assert AccountLinks.credential(session.instance_id, :owner).access_token == "owner-token"
      assert session.screen.credentials == []

      {:ok, session} = Setup.advance(session, %{"option_id" => "server-a"})

      dump = inspect(session, limit: :infinity, printable_limit: :infinity)
      refute dump =~ "owner-token"
      refute dump =~ "endpoint-token-a"
    end

    test "an unknown option keeps the screen and reports an error", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil)
      session = poll_until_choice(session)

      {:ok, after_bad} = Setup.advance(session, %{"option_id" => "nope"})

      assert after_bad.screen == session.screen
      assert after_bad.error == "Choose one of the options."
    end

    test "one Mydia user cannot take two remote accounts", %{slug: slug} do
      user = user_fixture()
      {:ok, session} = Setup.start(slug, nil)
      session = poll_until_choice(session)
      {:ok, session} = Setup.advance(session, %{"option_id" => "server-b"})

      {:ok, after_bad} =
        Setup.advance(session, %{"mapping" => %{"acct-1" => user.id, "acct-2" => user.id}})

      assert after_bad.error == "Each Mydia user can be linked to one account."
      assert {:mapping, _} = after_bad.screen.body
      assert Enum.filter(AccountLinks.list(session.instance_id), &(&1.role == :user)) == []
    end

    test "advancing an external-auth screen is refused", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil)

      {:ok, session} = Setup.advance(session, %{})

      assert session.error == "Waiting for sign-in to finish."
    end
  end

  describe "mapping suggestions" do
    # Fixture accounts (Task 1 table): acct-1 "Remote Alice" (admin), acct-2 "Remote Bob".
    defp to_mapping(slug, instance) do
      {:ok, session} = Setup.start(slug, instance)
      session = poll_until_choice(session)
      {:ok, session} = Setup.advance(session, %{"option_id" => "server-b"})
      {:mapping, mapping} = session.screen.body
      mapping.suggestions
    end

    defp instance!(slug, settings \\ %{}) do
      {:ok, instance} = Instances.create(slug, %{name: "Den", enabled: true, settings: settings})
      instance
    end

    test "the guest's own suggestion wins over a username match", %{slug: slug} do
      _name_match = user_fixture(%{username: "remote alice"})
      chosen = user_fixture()

      suggestions = to_mapping(slug, instance!(slug, %{"suggest_user_id" => chosen.id}))

      assert %{remote_account_id: "acct-1", user_id: chosen.id} in suggestions
      refute Enum.any?(suggestions, &(&1.remote_account_id == "acct-2"))
    end

    test "an existing link on the instance pre-fills its account", %{slug: slug} do
      linked = user_fixture()
      instance = instance!(slug)

      {:ok, _} =
        AccountLinks.replace_user_links(
          instance.id,
          [%{remote_account_id: "acct-2", remote_username: "Remote Bob", user_id: linked.id}],
          :admin_mapped
        )

      assert %{remote_account_id: "acct-2", user_id: linked.id} in to_mapping(slug, instance)
    end

    test "account names match usernames case-insensitively", %{slug: slug} do
      bob = user_fixture(%{username: "remote bob"})

      assert %{remote_account_id: "acct-2", user_id: bob.id} in to_mapping(slug, instance!(slug))
    end

    test "an admin account gets the sole Mydia admin", %{slug: slug} do
      admin = user_fixture(%{role: "admin"})

      assert %{remote_account_id: "acct-1", user_id: admin.id} in to_mapping(
               slug,
               instance!(slug)
             )
    end

    test "two Mydia admins mean no admin guess", %{slug: slug} do
      _a = user_fixture(%{role: "admin"})
      _b = user_fixture(%{role: "admin"})

      refute Enum.any?(to_mapping(slug, instance!(slug)), &(&1.remote_account_id == "acct-1"))
    end

    test "a user already suggested is not suggested for a second account", %{slug: slug} do
      shared = user_fixture()
      instance = instance!(slug, %{"suggest_user_id" => shared.id})

      {:ok, _} =
        AccountLinks.replace_user_links(
          instance.id,
          [%{remote_account_id: "acct-2", remote_username: "Remote Bob", user_id: shared.id}],
          :admin_mapped
        )

      suggestions = to_mapping(slug, instance)

      assert %{remote_account_id: "acct-1", user_id: shared.id} in suggestions
      refute Enum.any?(suggestions, &(&1.remote_account_id == "acct-2"))
    end

    test "an empty account list is filled from the instance's proposed accounts", %{slug: slug} do
      carol = user_fixture(%{username: "carol_remote"})
      instance = instance!(slug)

      {:ok, _} =
        Instances.set_remote_accounts(instance, [
          %{"id" => "p-1", "name" => "Carol_Remote", "admin" => false}
        ])

      enriched =
        Setup.enrich_mapping(%{title: "Link", accounts: [], suggestions: []}, instance.id)

      assert enriched.accounts == [%{id: "p-1", name: "Carol_Remote", admin: false}]
      assert enriched.suggestions == [%{remote_account_id: "p-1", user_id: carol.id}]
    end
  end

  describe "the manual form" do
    test "requires required fields before calling the guest", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil, step: "manual-start")

      {:ok, session} = Setup.advance(session, %{"url" => "", "token" => "t"})

      assert session.error == "Server URL is required."
      assert {:form, _} = session.screen.body
    end

    test "approves the typed url, stores declared settings and the returned credential",
         %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil, step: "manual-start")

      {:ok, session} =
        Setup.advance(session, %{"url" => "http://192.168.1.20:32400", "token" => "typed-token"})

      assert session.status == :done
      instance = Instances.get!(session.instance_id)

      assert %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400} in instance.approved_endpoints

      # "url" is declared in settings_schema; "token" is not, so it is not persisted.
      assert instance.settings["url"] == "http://192.168.1.20:32400"
      refute Map.has_key?(instance.settings, "token")
      assert AccountLinks.credential(instance.id, :owner).access_token == "typed-token"
    end

    test "an unusable port is shown to the operator, not raised", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil, step: "manual-start")

      {:ok, after_bad} =
        Setup.advance(session, %{"url" => "http://plex.lan:99999", "token" => "t"})

      assert after_bad.error =~ "http://plex.lan:99999"
      assert after_bad.error =~ "not valid"
      assert after_bad.status == :active
      assert Instances.get!(session.instance_id).approved_endpoints == []
    end

    test "an empty optional token yields no owner credential", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil, step: "manual-start")

      {:ok, session} = Setup.advance(session, %{"url" => "http://10.0.0.5:32400", "token" => ""})

      assert session.status == :done
      assert AccountLinks.credential(session.instance_id, :owner) == nil
    end
  end

  describe "cancel/1" do
    test "deletes a draft instance", %{slug: slug} do
      {:ok, session} = Setup.start(slug, nil)

      assert :ok = Setup.cancel(session)
      assert Instances.get(session.instance_id) == nil
    end

    test "on an existing instance removes only the endpoints approved in this session",
         %{slug: slug} do
      {:ok, instance} = Instances.create(slug, %{name: "Attic", enabled: true})

      {:ok, instance} =
        Instances.approve_endpoints(instance, [
          %{"scheme" => "https", "host" => "old.example.invalid", "port" => 443}
        ])

      {:ok, session} = Setup.start(slug, instance)
      session = poll_until_choice(session)
      {:ok, session} = Setup.advance(session, %{"option_id" => "server-a"})

      assert :ok = Setup.cancel(session)

      instance = Instances.get!(instance.id)
      assert instance.enabled

      assert instance.approved_endpoints == [
               %{"scheme" => "https", "host" => "old.example.invalid", "port" => 443}
             ]
    end
  end

  describe "endpoint_from_url/1" do
    test "parses scheme, host and port with scheme defaults" do
      assert {:ok, %{"scheme" => "https", "host" => "a.example.invalid", "port" => 443}} =
               Setup.endpoint_from_url("https://a.example.invalid/web")

      assert {:ok, %{"scheme" => "http", "host" => "10.0.0.2", "port" => 32400}} =
               Setup.endpoint_from_url("http://10.0.0.2:32400")

      assert :error = Setup.endpoint_from_url("ftp://a.example.invalid")
      assert :error = Setup.endpoint_from_url("not a url")
    end
  end
end
