defmodule Mydia.LibraryApi.RevisionCursorTest do
  use ExUnit.Case, async: true

  alias Mydia.LibraryApi.RevisionCursor

  test "round trips a positive revision without padding" do
    encoded = RevisionCursor.encode(42)
    refute encoded =~ "="
    assert {:ok, 42} = RevisionCursor.decode(encoded)
  end

  test "rejects malformed, old, zero, and negative payloads" do
    for payload <- ["garbage", "2026-09-12T00:00:00Z|uuid", "v1:0", "v1:-1", "v2:1"] do
      cursor = Base.url_encode64(payload, padding: false)
      assert :error = RevisionCursor.decode(cursor)
    end
  end

  test "an undecodable or non-binary cursor is an error, not a crash" do
    assert RevisionCursor.decode("not a base64 cursor!") == :error
    assert RevisionCursor.decode(nil) == :error

    for not_a_binary <- [42, :revision, %{revision: 1}] do
      assert RevisionCursor.decode(not_a_binary) == :error
    end
  end
end
