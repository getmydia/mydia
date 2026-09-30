defmodule Mydia.Repo.Migrations.PluginContract14Test do
  # async: false: creates a legacy table with DDL inside the sandbox.
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.AccountsFixtures

  alias Mydia.Plugins.AccountLink
  alias Mydia.Plugins.Instance
  alias Mydia.Repo
  alias Mydia.Settings

  # Migration modules are not compiled into the app; load the file explicitly.
  # Guarded because the test alias already ran `ecto.migrate` in this VM.
  unless Code.ensure_loaded?(Mydia.Repo.Migrations.PluginContract14) do
    Code.require_file("priv/repo/migrations/20260929141207_plugin_contract_1_4.exs")
  end

  alias Mydia.Repo.Migrations.PluginContract14

  defp plugin_config(slug, attrs \\ %{}) do
    {:ok, config} =
      Settings.create_plugin_config(
        Map.merge(
          %{
            slug: slug,
            name: "Name #{slug}",
            version: "1.0.0",
            enabled: true,
            settings: %{"client_id" => "abc"}
          },
          attrs
        )
      )

    Repo.query!("UPDATE plugin_configs SET consecutive_schedule_failures = 2 WHERE slug = $1", [
      slug
    ])

    config
  end

  # The migrated test database no longer has plugin_user_connections; recreate
  # the legacy shape inside the sandbox so the copy step has something to read.
  defp postgres?, do: Mydia.DB.postgres?()

  defp create_legacy_connections_table do
    {id, ts} = if postgres?(), do: {"uuid", "timestamp"}, else: {"TEXT", "TEXT"}

    Repo.query!("""
    CREATE TABLE plugin_user_connections (
      id #{id} PRIMARY KEY,
      plugin_config_id #{id} NOT NULL,
      plugin_slug text NOT NULL,
      user_id #{id} NOT NULL,
      status text NOT NULL,
      access_token text,
      external_user_id text,
      external_username text,
      meta text,
      inserted_at #{ts} NOT NULL,
      updated_at #{ts} NOT NULL
    )
    """)
  end

  defp legacy_params(config, user) do
    now = DateTime.utc_now()

    if postgres?(),
      do: [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        Ecto.UUID.dump!(config.id),
        Ecto.UUID.dump!(user.id),
        now
      ],
      else: [Ecto.UUID.generate(), config.id, user.id, DateTime.to_iso8601(now)]
  end

  test "creates one default instance per plugin config, copying settings" do
    config = plugin_config("legacy_one")

    assert :ok = PluginContract14.backfill()
    assert :ok = PluginContract14.backfill()

    assert [%Instance{} = inst] =
             Repo.all(from i in Instance, where: i.plugin_slug == "legacy_one")

    assert inst.plugin_config_id == config.id
    assert inst.name == "Name legacy_one"
    assert inst.settings == %{"client_id" => "abc"}
    assert inst.schedule_failures == 2
  end

  test "backfills instance_id on kv rows that lack one" do
    config = plugin_config("legacy_kv")
    now = DateTime.utc_now()

    Repo.insert_all("plugin_kv", [
      %{
        id: Ecto.UUID.bingenerate() |> maybe_string_uuid(),
        plugin_config_id: dump_uuid(config.id),
        plugin_slug: "legacy_kv",
        key: "cursor",
        value: "1",
        inserted_at: now,
        updated_at: now
      }
    ])

    assert :ok = PluginContract14.backfill()

    inst = Repo.one!(from i in Instance, where: i.plugin_slug == "legacy_kv")

    assert [inst.id] ==
             Repo.all(
               from k in "plugin_kv",
                 where: k.plugin_slug == "legacy_kv",
                 select: type(k.instance_id, :binary_id)
             )
  end

  test "copies legacy connections into account links with active status" do
    config = plugin_config("legacy_conn")
    user = user_fixture()
    create_legacy_connections_table()

    Repo.query!(
      """
      INSERT INTO plugin_user_connections
        (id, plugin_config_id, plugin_slug, user_id, status, access_token,
         external_user_id, external_username, meta, inserted_at, updated_at)
      VALUES ($1, $2, 'legacy_conn', $3, 'connected', 'tok', 'ext-1', 'robin', '{}', $4, $4)
      """,
      legacy_params(config, user)
    )

    assert :ok = PluginContract14.backfill()
    assert :ok = PluginContract14.backfill()

    assert [%AccountLink{} = link] =
             Repo.all(from l in AccountLink, where: l.plugin_slug == "legacy_conn")

    assert link.user_id == user.id
    assert link.role == :user
    assert link.source == :user_flow
    assert link.status == :active
    assert link.access_token == "tok"
    assert link.external_username == "robin"
  end

  test "two users who linked the same external account both keep their link" do
    config = plugin_config("legacy_dup")
    first = user_fixture()
    second = user_fixture()
    create_legacy_connections_table()

    for {user, at} <- [{first, "2026-01-01 00:00:00"}, {second, "2026-02-01 00:00:00"}] do
      [id, cfg, uid, _now] = legacy_params(config, user)
      ts = if postgres?(), do: NaiveDateTime.from_iso8601!(at), else: at

      Repo.query!(
        """
        INSERT INTO plugin_user_connections
          (id, plugin_config_id, plugin_slug, user_id, status, access_token,
           external_user_id, external_username, meta, inserted_at, updated_at)
        VALUES ($1, $2, 'legacy_dup', $3, 'connected', 'tok', 'shared-ext', 'robin', '{}', $4, $4)
        """,
        [id, cfg, uid, ts]
      )
    end

    assert :ok = PluginContract14.backfill()

    links = Repo.all(from l in AccountLink, where: l.plugin_slug == "legacy_dup")
    assert Enum.sort(Enum.map(links, & &1.user_id)) == Enum.sort([first.id, second.id])

    assert Enum.find(links, &(&1.user_id == first.id)).external_user_id == "shared-ext"
    assert Enum.find(links, &(&1.user_id == second.id)).external_user_id == nil
  end

  defp dump_uuid(id) do
    if postgres?(), do: Ecto.UUID.dump!(id), else: id
  end

  defp maybe_string_uuid(bin) do
    if postgres?(), do: bin, else: Ecto.UUID.load!(bin)
  end
end
