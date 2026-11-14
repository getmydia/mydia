defmodule MetadataRelay.Backup.HandlerTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.{Backup, RateLimiter, Repo, Router}

  @json "application/vnd.mydia.backup"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    case GenServer.whereis(RateLimiter) do
      nil -> start_supervised!(RateLimiter)
      _pid -> :ok
    end

    :ets.delete_all_objects(:rate_limiter)

    dir = Path.join(System.tmp_dir!(), "backup_handler_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env!(:metadata_relay, :backup)
    Application.put_env(:metadata_relay, :backup, Keyword.put(previous, :dir, dir))

    on_exit(fn ->
      Application.put_env(:metadata_relay, :backup, previous)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp unb64(text), do: Base.url_decode64!(text, padding: false)
  defp keypair, do: :crypto.generate_key(:eddsa, :ed25519)

  defp slot_id(pub),
    do: :crypto.hash(:sha256, pub) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  defp box(pub), do: :crypto.hash(:sha256, "box" <> pub)

  defp auth(%{pub: pub, priv: priv}, method, path, body, ts) do
    hash = Base.encode16(:crypto.hash(:sha256, body), case: :lower)

    sig =
      :crypto.sign(:eddsa, :none, "#{method}\n#{path}\n#{hash}\n#{ts}", [priv, :ed25519])

    "MydiaSig signer=#{b64(pub)}, ts=#{ts}, sig=#{b64(sig)}"
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp signed(key, method, path, body \\ "", opts \\ []) do
    ts = Keyword.get(opts, :ts, now_ms())
    type = Keyword.get(opts, :type, @json)

    Plug.Test.conn(String.to_existing_atom(String.downcase(method)), path, body)
    |> Plug.Conn.put_req_header("authorization", auth(key, method, path, body, ts))
    |> Plug.Conn.put_req_header("content-type", type)
    |> then(fn conn ->
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)
    end)
    |> Router.call([])
  end

  defp key do
    {pub, priv} = keypair()
    %{pub: pub, priv: priv}
  end

  defp create_body(first, recovery, handle) do
    Jason.encode!(%{
      signer: b64(first.pub),
      slot_id: slot_id(first.pub),
      envelope: b64("env-1"),
      box_pub: b64(box(first.pub)),
      recovery_signer: b64(recovery.pub),
      recovery_slot_id: slot_id(recovery.pub),
      recovery_envelope: b64("renv-1"),
      recovery_box_pub: b64(box(recovery.pub)),
      lookup_hash: Base.encode16(:crypto.hash(:sha256, handle), case: :lower)
    })
  end

  defp post_vaults(body, type \\ @json) do
    Plug.Test.conn(:post, "/backup/v1/vaults", body)
    |> Plug.Conn.put_req_header("content-type", type)
    |> Router.call([])
  end

  defp new_vault do
    first = key()
    recovery = key()
    handle = :crypto.strong_rand_bytes(32)
    conn = post_vaults(create_body(first, recovery, handle))
    assert conn.status == 201
    %{"vault_id" => id} = Jason.decode!(conn.resp_body)
    %{id: id, first: first, recovery: recovery, handle: handle}
  end

  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]

  test "create, lookup, put slot, manifest, etag, get slot, delete" do
    %{id: id, first: first, handle: handle} = new_vault()
    assert id =~ ~r/\A[0-9a-f]{32}\z/

    lookup = Plug.Test.conn(:get, "/backup/v1/lookup/#{b64(handle)}") |> Router.call([])
    assert lookup.status == 200
    assert %{"vault_id" => ^id} = Jason.decode!(lookup.resp_body)

    sid = slot_id(first.pub)
    slot_path = "/backup/v1/vaults/#{id}/slots/#{sid}"

    put =
      signed(first, "PUT", slot_path, "ciphertext-1",
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}]
      )

    assert put.status == 200
    assert %{"seq" => 1} = Jason.decode!(put.resp_body)
    assert Plug.Conn.get_resp_header(put, "etag") == ["\"1\""]

    manifest_path = "/backup/v1/vaults/#{id}"
    manifest = signed(first, "GET", manifest_path)
    assert manifest.status == 200
    [etag] = Plug.Conn.get_resp_header(manifest, "etag")
    body = Jason.decode!(manifest.resp_body)
    assert body["epoch"] == 1
    assert unb64(body["envelope"]) == "env-1"
    assert body["recovery_signer"] != nil
    assert [%{"slot_id" => ^sid, "seq" => 1, "epoch" => 1, "size" => 12} = s] = body["slots"]
    assert is_integer(s["updated_at"])
    assert length(body["members"]) == 2
    assert Enum.any?(body["members"], & &1["recovery"])

    mine = Enum.find(body["members"], &(&1["slot_id"] == sid))
    assert unb64(mine["signer"]) == first.pub
    assert unb64(mine["box_pub"]) == box(first.pub)

    cached = signed(first, "GET", manifest_path, "", headers: [{"if-none-match", etag}])
    assert cached.status == 304

    slot = signed(first, "GET", slot_path)
    assert slot.status == 200
    assert slot.resp_body == "ciphertext-1"
    assert Plug.Conn.get_resp_header(slot, "etag") == ["\"1\""]
    assert ["application/octet-stream" <> _] = Plug.Conn.get_resp_header(slot, "content-type")

    same = signed(first, "GET", slot_path, "", headers: [{"if-none-match", "\"1\""}])
    assert same.status == 304

    update =
      signed(first, "PUT", slot_path, "ciphertext-2",
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}, {"if-match", "1"}]
      )

    assert %{"seq" => 2} = Jason.decode!(update.resp_body)

    stale =
      signed(first, "PUT", slot_path, "ciphertext-3",
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}, {"if-match", "1"}]
      )

    assert stale.status == 412

    wrong_epoch =
      signed(first, "PUT", slot_path, "x",
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "7"}, {"if-match", "2"}]
      )

    assert wrong_epoch.status == 409
    assert error(wrong_epoch) == "stale_epoch"

    deleted = signed(first, "DELETE", manifest_path)
    assert deleted.status == 204
    assert Backup.lookup(handle) == {:error, :not_found}
  end

  test "an unknown vault is 404 vault_not_found, other 404s are not_found" do
    first = key()
    conn = signed(first, "GET", "/backup/v1/vaults/#{String.duplicate("a", 32)}")
    assert conn.status == 404
    assert conn.resp_body == ~s({"error":"vault_not_found"})

    %{id: id, first: member} = new_vault()
    missing = signed(member, "GET", "/backup/v1/vaults/#{id}/slots/#{slot_id("none")}")
    assert missing.status == 404
    assert error(missing) == "not_found"

    miss = Plug.Test.conn(:get, "/backup/v1/lookup/#{b64(:crypto.strong_rand_bytes(32))}")
    miss = Router.call(miss, [])
    assert miss.status == 404
    assert error(miss) == "not_found"
  end

  test "unsigned and badly signed requests are 401" do
    %{id: id, first: first} = new_vault()
    path = "/backup/v1/vaults/#{id}"

    unsigned = Plug.Test.conn(:get, path) |> Router.call([])
    assert unsigned.status == 401
    assert error(unsigned) == "missing"

    forged =
      Plug.Test.conn(:get, path)
      |> Plug.Conn.put_req_header("authorization", auth(first, "GET", path <> "x", "", now_ms()))
      |> Router.call([])

    assert forged.status == 401
    assert error(forged) == "bad_signature"

    junk =
      Plug.Test.conn(:get, path)
      |> Plug.Conn.put_req_header("authorization", "Bearer abc")
      |> Router.call([])

    assert junk.status == 401
    assert error(junk) == "malformed"
  end

  test "a skewed timestamp is 401 with the server time" do
    %{id: id, first: first} = new_vault()
    before = now_ms()
    conn = signed(first, "GET", "/backup/v1/vaults/#{id}", "", ts: before - 600_000)
    assert conn.status == 401
    assert error(conn) == "skew"
    [server_time] = Plug.Conn.get_resp_header(conn, "x-backup-server-time")
    assert abs(String.to_integer(server_time) - before) < 5_000
  end

  test "a valid signature by a non-member is 403" do
    %{id: id} = new_vault()
    stranger = key()
    conn = signed(stranger, "GET", "/backup/v1/vaults/#{id}")
    assert conn.status == 403
    assert error(conn) == "not_member"
  end

  test "a member cannot write another member's slot" do
    %{id: id, first: first} = new_vault()

    conn =
      signed(first, "PUT", "/backup/v1/vaults/#{id}/slots/#{slot_id("other")}", "x",
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}]
      )

    assert conn.status == 403
    assert error(conn) == "not_owner"
  end

  test "an oversize slot is 413, exactly the limit is accepted" do
    %{id: id, first: first} = new_vault()
    path = "/backup/v1/vaults/#{id}/slots/#{slot_id(first.pub)}"

    big = :binary.copy("a", 4_194_304 + 1)

    over =
      signed(first, "PUT", path, big,
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}]
      )

    assert over.status == 413
    assert error(over) == "too_large"

    ok =
      signed(first, "PUT", path, :binary.copy("a", 4_194_304),
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}]
      )

    assert ok.status == 200
  end

  test "an oversize content-length is rejected before the body is read" do
    %{id: id, first: first} = new_vault()
    path = "/backup/v1/vaults/#{id}/slots/#{slot_id(first.pub)}"

    conn =
      signed(first, "PUT", path, "x",
        type: "application/octet-stream",
        headers: [{"x-backup-epoch", "1"}, {"content-length", "5000000"}]
      )

    assert conn.status == 413
  end

  test "POST /vaults rejects invalid bodies and a taken lookup" do
    bad = post_vaults("not json")
    assert bad.status == 422
    assert error(bad) == "invalid"

    missing = post_vaults(Jason.encode!(%{signer: "x"}))
    assert missing.status == 422

    first = key()
    recovery = key()
    handle = :crypto.strong_rand_bytes(32)
    assert post_vaults(create_body(first, recovery, handle)).status == 201
    taken = post_vaults(create_body(key(), key(), handle))
    assert taken.status == 422
    assert taken.resp_body == ~s({"error":"lookup_taken"})
  end

  test "POST /vaults is limited to 10 per address per hour, lookup to 30" do
    for _ <- 1..10, do: post_vaults("not json")
    assert post_vaults("not json").status == 429

    path = "/backup/v1/lookup/#{b64(:crypto.strong_rand_bytes(32))}"
    for _ <- 1..30, do: Router.call(Plug.Test.conn(:get, path), [])
    assert Router.call(Plug.Test.conn(:get, path), []).status == 429
  end

  test "members: add a device, rotate to remove one" do
    %{id: id, first: first, recovery: recovery} = new_vault()
    second = key()
    path = "/backup/v1/vaults/#{id}/members"

    add =
      Jason.encode!(%{
        expected_epoch: 1,
        new_epoch: 1,
        add: [
          %{
            signer: b64(second.pub),
            slot_id: slot_id(second.pub),
            box_pub: b64(box(second.pub))
          }
        ],
        envelopes: %{b64(second.pub) => b64("env-second")}
      })

    # The recovery signer adds a restoring device.
    conn = signed(recovery, "POST", path, add)
    assert conn.status == 200
    assert %{"epoch" => 1} = Jason.decode!(conn.resp_body)

    conflict =
      signed(recovery, "POST", path, Jason.encode!(%{expected_epoch: 5, new_epoch: 5}))

    assert conflict.status == 409
    assert error(conflict) == "conflict"

    rotate =
      Jason.encode!(%{
        expected_epoch: 1,
        new_epoch: 2,
        remove: [b64(first.pub)],
        envelopes: %{
          b64(second.pub) => b64("env-second-2"),
          b64(recovery.pub) => b64("renv-2")
        }
      })

    conn = signed(second, "POST", path, rotate)
    assert conn.status == 200
    assert %{"epoch" => 2} = Jason.decode!(conn.resp_body)

    gone = signed(first, "GET", "/backup/v1/vaults/#{id}")
    assert gone.status == 403

    invalid = signed(second, "POST", path, Jason.encode!(%{expected_epoch: "x"}))
    assert invalid.status == 422

    garbled = signed(second, "POST", path, "nope")
    assert garbled.status == 422
  end

  test "members: replacing the recovery key" do
    %{id: id, first: first} = new_vault()
    new_recovery = key()
    handle = :crypto.strong_rand_bytes(32)

    body =
      Jason.encode!(%{
        expected_epoch: 1,
        new_epoch: 2,
        envelopes: %{b64(first.pub) => b64("env-2")},
        recovery: %{
          signer: b64(new_recovery.pub),
          slot_id: slot_id(new_recovery.pub),
          envelope: b64("renv-2"),
          box_pub: b64(box(new_recovery.pub)),
          lookup_hash: Base.encode16(:crypto.hash(:sha256, handle), case: :lower)
        }
      })

    conn = signed(first, "POST", "/backup/v1/vaults/#{id}/members", body)
    assert conn.status == 200
    assert {:ok, ^id} = Backup.lookup(handle)
  end

  test "member changes share the 120 writes per hour budget" do
    %{id: id, first: first} = new_vault()
    for _ <- 1..120, do: Backup.charge_write(id)

    conn =
      signed(
        first,
        "POST",
        "/backup/v1/vaults/#{id}/members",
        Jason.encode!(%{expected_epoch: 1})
      )

    assert conn.status == 429
    assert error(conn) == "rate_limited"
  end

  test "backup responses are never cached by the relay" do
    %{id: id, first: first} = new_vault()
    path = "/backup/v1/vaults/#{id}"
    assert signed(first, "GET", path).status == 200
    # A second request with a different signature must reach the handler.
    stranger = key()
    assert signed(stranger, "GET", path).status == 403
  end
end
