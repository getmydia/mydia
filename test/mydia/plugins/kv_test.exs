defmodule Mydia.Plugins.KvTest do
  # async: false because the quota tests swap :runtime_config.
  use Mydia.DataCase, async: false

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Kv
  alias Mydia.Settings

  defp install!(slug) do
    {:ok, _config} =
      Settings.create_plugin_config(%{
        slug: slug,
        name: slug,
        version: "1.0.0",
        source_url: "test",
        manifest: %{
          "slug" => slug,
          "name" => slug,
          "version" => "1.0.0",
          "capabilities" => %{"events:subscribe" => ["media_item.added"], "state:kv" => []}
        },
        granted_capabilities: %{"state:kv" => []},
        enabled: false
      })

    {:ok, instance} = Instances.create(slug, %{name: "#{slug} one"})
    instance
  end

  defp put_limits(keys, bytes) do
    original = Application.get_env(:mydia, :runtime_config)
    defaults = Mydia.Config.Schema.defaults()
    base = original || defaults
    plugins = %{base.plugins | store_max_keys: keys, store_max_bytes: bytes}
    Application.put_env(:mydia, :runtime_config, %{base | plugins: plugins})

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :runtime_config, original),
        else: Application.delete_env(:mydia, :runtime_config)
    end)
  end

  setup do
    {:ok, instance: install!("kvtest")}
  end

  describe "get/set/delete" do
    test "set then get round-trips", %{instance: i} do
      assert {:ok, "v1"} = Kv.set(i.id, "k", "v1")
      assert {:ok, "v1"} = Kv.get(i.id, "k")
    end

    test "get on a missing key returns nil", %{instance: i} do
      assert {:ok, nil} = Kv.get(i.id, "absent")
    end

    test "set overwrites without a constraint error", %{instance: i} do
      for v <- ~w(a b c), do: assert({:ok, ^v} = Kv.set(i.id, "k", v))
      assert {:ok, "c"} = Kv.get(i.id, "k")
      assert %{keys: 1, bytes: 2} = Kv.usage(i.id)
    end

    test "delete removes the key and is a no-op when absent", %{instance: i} do
      {:ok, _} = Kv.set(i.id, "k", "v")
      assert :ok = Kv.delete(i.id, "k")
      assert {:ok, nil} = Kv.get(i.id, "k")
      assert :ok = Kv.delete(i.id, "k")
    end

    test "set on a missing instance returns not_found" do
      assert {:error, %Error{type: :not_found}} = Kv.set(Ecto.UUID.generate(), "k", "v")
    end
  end

  describe "instance isolation" do
    test "two instances of one plugin hold the same key independently", %{instance: a} do
      {:ok, b} = Instances.create("kvtest", %{name: "kvtest two"})
      {:ok, _} = Kv.set(a.id, "shared", "from-a")
      {:ok, _} = Kv.set(b.id, "shared", "from-b")

      assert {:ok, "from-a"} = Kv.get(a.id, "shared")
      assert {:ok, "from-b"} = Kv.get(b.id, "shared")
    end
  end

  describe "set_many/2" do
    test "writes every entry and the last duplicate wins", %{instance: i} do
      assert :ok = Kv.set_many(i.id, [{"a", "1"}, {"b", "2"}, {"a", "3"}])
      assert {:ok, "3"} = Kv.get(i.id, "a")
      assert {:ok, "2"} = Kv.get(i.id, "b")
    end

    test "an oversized value rejects the whole batch", %{instance: i} do
      big = String.duplicate("x", Kv.max_value_bytes() + 1)

      assert {:error, %Error{type: :invalid_request}} =
               Kv.set_many(i.id, [{"ok", "1"}, {"big", big}])

      assert {:ok, nil} = Kv.get(i.id, "ok")
    end

    test "an oversized key or empty key rejects the batch", %{instance: i} do
      long = String.duplicate("k", 513)
      assert {:error, %Error{type: :invalid_request}} = Kv.set_many(i.id, [{long, "v"}])
      assert {:error, %Error{type: :invalid_request}} = Kv.set_many(i.id, [{"", "v"}])
    end

    test "a batch larger than max_batch is rejected", %{instance: i} do
      entries = for n <- 1..(Kv.max_batch() + 1), do: {"k#{n}", "v"}
      assert {:error, %Error{type: :invalid_request}} = Kv.set_many(i.id, entries)
    end
  end

  describe "quotas" do
    test "the key quota bites new keys only, and denies the whole batch", %{instance: i} do
      put_limits(3, 1_000_000)
      :ok = Kv.set_many(i.id, [{"k1", "v"}, {"k2", "v"}, {"k3", "v"}])

      assert {:error, %Error{type: :capability_denied, message: "store quota exceeded" <> _}} =
               Kv.set_many(i.id, [{"k1", "new"}, {"k4", "v"}])

      assert {:ok, "v"} = Kv.get(i.id, "k1")
      assert :ok = Kv.set_many(i.id, [{"k1", "updated"}])
      assert {:ok, "updated"} = Kv.get(i.id, "k1")
    end

    test "the byte quota counts key + value bytes and credits overwrites", %{instance: i} do
      # "k1" + 8 bytes = 10 bytes per row.
      put_limits(1_000, 20)
      :ok = Kv.set_many(i.id, [{"k1", "12345678"}, {"k2", "12345678"}])
      assert %{bytes: 20} = Kv.usage(i.id)

      assert {:error, %Error{type: :capability_denied}} = Kv.set(i.id, "k3", "x")
      # Shrinking an existing value always fits.
      assert {:ok, "1"} = Kv.set(i.id, "k1", "1")
      assert %{bytes: 13} = Kv.usage(i.id)
    end

    test "defaults come from the plugins config" do
      assert Kv.max_keys() == 200_000
      assert Kv.max_bytes() == 67_108_864
    end
  end

  describe "list/3" do
    test "returns only the prefix, in key order, paged by 200", %{instance: i} do
      entries = for n <- 1..205, do: {"map/#{String.pad_leading("#{n}", 3, "0")}", "v#{n}"}
      :ok = Kv.set_many(i.id, entries ++ [{"other/1", "x"}, {"maq", "not a prefix hit"}])

      assert {:ok, %{entries: page1, next_cursor: cursor}} = Kv.list(i.id, "map/", nil)
      assert length(page1) == 200
      assert hd(page1) == {"map/001", "v1"}
      assert is_binary(cursor)

      assert {:ok, %{entries: page2, next_cursor: nil}} = Kv.list(i.id, "map/", cursor)
      assert Enum.map(page2, &elem(&1, 0)) == ~w(map/201 map/202 map/203 map/204 map/205)
    end

    test "an empty prefix lists everything", %{instance: i} do
      :ok = Kv.set_many(i.id, [{"b", "2"}, {"a", "1"}])

      assert {:ok, %{entries: [{"a", "1"}, {"b", "2"}], next_cursor: nil}} =
               Kv.list(i.id, "", nil)
    end

    test "LIKE wildcards in the prefix are literal", %{instance: i} do
      :ok = Kv.set_many(i.id, [{"a_b/1", "x"}, {"aXb/1", "y"}, {"a%/1", "z"}])
      assert {:ok, %{entries: [{"a_b/1", "x"}]}} = Kv.list(i.id, "a_b/", nil)
      assert {:ok, %{entries: [{"a%/1", "z"}]}} = Kv.list(i.id, "a%/", nil)
    end

    test "a malformed cursor is invalid_request", %{instance: i} do
      assert {:error, %Error{type: :invalid_request}} = Kv.list(i.id, "", "!!")
    end
  end

  describe "prefix sweeps" do
    test "delete_link_prefix removes link/<id>/ and legacy conn/<id>/ keys only", %{instance: i} do
      :ok =
        Kv.set_many(i.id, [
          {"link/abc/state/m:1", "1"},
          {"link/abc/cursor/pull", "2"},
          {"conn/abc/watermark", "3"},
          {"link/xyz/cursor/pull", "4"},
          {"global", "5"}
        ])

      assert Kv.delete_link_prefix(i.id, "abc") == 3
      assert {:ok, %{entries: rest}} = Kv.list(i.id, "", nil)
      assert Enum.map(rest, &elem(&1, 0)) == ["global", "link/xyz/cursor/pull"]
    end
  end
end
