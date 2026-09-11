defmodule Mydia.LibraryApi.CursorTest do
  use ExUnit.Case, async: true

  alias Mydia.LibraryApi.Cursor

  test "round trips a second-precision timestamp and a uuid" do
    # updated_at is :utc_datetime, so second precision is exact, not lossy.
    ts = ~U[2026-09-11 12:34:56Z]
    id = "9b1c0f4e-2a3b-4c5d-8e7f-0a1b2c3d4e5f"

    assert {:ok, {^ts, ^id}} = Cursor.decode(Cursor.encode(ts, id))
  end

  test "the encoded cursor is base64url and does not leak the separator unencoded" do
    encoded = Cursor.encode(~U[2026-09-11 00:00:00Z], "abc")
    refute encoded =~ "|"
    refute encoded =~ "="
    assert Base.url_decode64(encoded, padding: false)
  end

  test "an undecodable cursor is an error, not a silent default" do
    assert Cursor.decode("not-a-cursor") == :error
    assert Cursor.decode(Base.url_encode64("nonsense", padding: false)) == :error
  end

  test "a cursor whose timestamp is not ISO8601 is an error" do
    assert Cursor.decode(Base.url_encode64("not-a-time|abc", padding: false)) == :error
  end

  test "a cursor whose id is empty, malformed, or has another segment is an error" do
    timestamp = "2026-09-11T00:00:00Z"

    for id <- ["", "not-a-uuid", "9b1c0f4e-2a3b-4c5d-8e7f-0a1b2c3d4e5f|another"] do
      cursor = Base.url_encode64("#{timestamp}|#{id}", padding: false)
      assert Cursor.decode(cursor) == :error
    end
  end
end
