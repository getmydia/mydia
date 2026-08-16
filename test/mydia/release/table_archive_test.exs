defmodule Mydia.Release.TableArchiveTest do
  use Mydia.DataCase, async: false

  alias Mydia.Release.TableArchive

  @moduletag :tmp_dir

  # SQLite's binary column type is `BLOB`; PostgreSQL's is `bytea`. Likewise
  # SQLite accepts a blob literal as `X'<hex>'`, while PostgreSQL only
  # recognises that spelling as a bit-string literal for the `bit` type — its
  # portable spelling for a bytea literal is the hex-format string
  # `'\xhexdigits'`, which the target column's type resolves the untyped
  # string literal into. Picking the adapter at runtime (rather than hardcoding
  # either syntax) is what lets this fixture run under both `Test / SQLite`
  # and `Test / PostgreSQL` in CI.
  #
  # Deliberately NOT `Mydia.Repo.Migrations.Helpers.postgres?/0`: that helper
  # calls `repo()`, which is only valid inside a running migration and raises
  # here.
  defp binary_column_type do
    case Mydia.Repo.__adapter__() do
      Ecto.Adapters.Postgres -> "bytea"
      _ -> "BLOB"
    end
  end

  defp binary_literal(hex) do
    case Mydia.Repo.__adapter__() do
      Ecto.Adapters.Postgres -> "'\\x#{hex}'"
      _ -> "X'#{hex}'"
    end
  end

  test "writes one NDJSON line per row and reports the count", %{tmp_dir: tmp_dir} do
    Mydia.Repo.query!("CREATE TABLE archive_fixture (id INTEGER, name TEXT)")
    Mydia.Repo.query!("INSERT INTO archive_fixture (id, name) VALUES (1, 'alpha')")
    Mydia.Repo.query!("INSERT INTO archive_fixture (id, name) VALUES (2, 'beta')")

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["archive_fixture"], tmp_dir)
    assert counts["archive_fixture"] == 2

    lines =
      Path.join(tmp_dir, "archive_fixture.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert length(lines) == 2
    decoded = Enum.map(lines, &Jason.decode!/1)
    assert %{"id" => 1, "name" => "alpha"} in decoded
    assert %{"id" => 2, "name" => "beta"} in decoded
  end

  test "skips an empty table and writes no file", %{tmp_dir: tmp_dir} do
    Mydia.Repo.query!("CREATE TABLE empty_fixture (id INTEGER)")

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["empty_fixture"], tmp_dir)
    assert counts["empty_fixture"] == 0
    refute File.exists?(Path.join(tmp_dir, "empty_fixture.ndjson"))
  end

  test "returns an error rather than raising when a table does not exist", %{tmp_dir: tmp_dir} do
    assert {:error, _reason} = TableArchive.archive_tables(Mydia.Repo, ["no_such_table"], tmp_dir)
  end

  # These tables archive `:binary_id` primary/foreign keys. SQLite maps
  # `:binary_id` to `:string`, so the plain-text-UUID case is already covered
  # by the tests above. What is not covered anywhere is what happens when raw
  # SQL hands back the 16-byte binary representation, which is exactly what
  # PostgreSQL's uuid extension returns. Exercise that here via an explicit
  # binary column and an adapter-appropriate blob literal (see
  # `binary_column_type/0` and `binary_literal/1` above), so the bytes
  # round-trip exactly as inserted regardless of how the driver binds
  # ordinary string parameters.
  #
  # The UUID is fixed rather than generated: the UUID branch now requires the
  # 16 bytes to be invalid UTF-8, and a random UUID is occasionally valid UTF-8
  # (roughly one run in tens of thousands), which would fail intermittently and
  # reproduce for nobody. This one leads with 0xFF, a byte that can never appear
  # in valid UTF-8, and the guard below keeps that true if anyone edits it.
  test "formats a 16-byte binary id as a canonical UUID string", %{tmp_dir: tmp_dir} do
    uuid = "ff0e8400-e29b-41d4-a716-446655440000"
    raw = Ecto.UUID.dump!(uuid)
    refute String.valid?(raw)

    hex = Base.encode16(raw)

    Mydia.Repo.query!("CREATE TABLE uuid_fixture (id #{binary_column_type()}, name TEXT)")

    Mydia.Repo.query!(
      "INSERT INTO uuid_fixture (id, name) VALUES (#{binary_literal(hex)}, 'widget')"
    )

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["uuid_fixture"], tmp_dir)
    assert counts["uuid_fixture"] == 1

    [line] =
      Path.join(tmp_dir, "uuid_fixture.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Jason.decode!(line) == %{"id" => uuid, "name" => "widget"}
  end

  # A 16-byte guard alone is not enough to identify a raw UUID: SQLite hands
  # back ordinary TEXT columns as plain Elixir binaries too, and plenty of
  # real strings happen to be exactly 16 bytes long. Without an additional
  # UTF-8 check, a title like "Boards of Canada" would be silently
  # reformatted into UUID-looking garbage
  # ("426f6172-6473-206f-6620-43616e616461") instead of archiving as itself.
  test "archives a 16-byte valid-UTF-8 TEXT value as its literal text, not a UUID", %{
    tmp_dir: tmp_dir
  } do
    name = "Boards of Canada"
    assert byte_size(name) == 16

    Mydia.Repo.query!("CREATE TABLE text_fixture (id INTEGER, name TEXT)")
    Mydia.Repo.query!("INSERT INTO text_fixture (id, name) VALUES (1, '#{name}')")

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["text_fixture"], tmp_dir)
    assert counts["text_fixture"] == 1

    [line] =
      Path.join(tmp_dir, "text_fixture.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Jason.decode!(line) == %{"id" => 1, "name" => "Boards of Canada"}
  end

  test "falls back to Base64 for a non-UUID-shaped binary that is not valid UTF-8", %{
    tmp_dir: tmp_dir
  } do
    # Deliberately not 16 bytes: any exactly-16-byte binary is treated as a
    # UUID by design (see the comment on `TableArchive.encodable/1`), so this
    # proves the general Base64 fallback still applies to binary blobs that
    # aren't UUID-shaped.
    invalid_utf8 = <<0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8>>
    hex = Base.encode16(invalid_utf8)

    Mydia.Repo.query!("CREATE TABLE blob_fixture (id INTEGER, payload #{binary_column_type()})")

    Mydia.Repo.query!("INSERT INTO blob_fixture (id, payload) VALUES (1, #{binary_literal(hex)})")

    assert {:ok, counts} = TableArchive.archive_tables(Mydia.Repo, ["blob_fixture"], tmp_dir)
    assert counts["blob_fixture"] == 1

    [line] =
      Path.join(tmp_dir, "blob_fixture.ndjson")
      |> File.read!()
      |> String.split("\n", trim: true)

    assert Jason.decode!(line) == %{"id" => 1, "payload" => Base.encode64(invalid_utf8)}
  end

  # `encodable/1` is exposed (not `defp`) specifically so these clauses can be
  # unit tested directly: SQLite's raw driver never hands back `%Date{}` /
  # `%Time{}` / `%NaiveDateTime{}` / `%DateTime{}` structs from a plain SQL
  # query (those only appear coming out of Postgrex), so there is no way to
  # reach them through `archive_tables/3` without a live Postgres connection.
  describe "encodable/1" do
    test "formats a DateTime as ISO 8601" do
      assert TableArchive.encodable(~U[2026-08-15 12:34:56Z]) == "2026-08-15T12:34:56Z"
    end

    test "formats a NaiveDateTime as ISO 8601" do
      assert TableArchive.encodable(~N[2026-08-15 12:34:56]) == "2026-08-15T12:34:56"
    end

    test "formats a Date as ISO 8601" do
      assert TableArchive.encodable(~D[2026-08-15]) == "2026-08-15"
    end

    test "formats a Time as ISO 8601" do
      assert TableArchive.encodable(~T[12:34:56]) == "12:34:56"
    end
  end
end
