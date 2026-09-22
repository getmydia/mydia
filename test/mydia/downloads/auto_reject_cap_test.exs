defmodule Mydia.Downloads.AutoRejectCapTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Downloads.AutoRejectCap

  defp burn(media_item_id, count) do
    for _ <- 1..count, do: Mydia.Search.record_failure("auto_reject", media_item_id, "stalled")
  end

  test "limit/0 defaults to 3" do
    assert AutoRejectCap.limit() == 3
  end

  describe "exhausted?/1" do
    test "an unbound download is never capped" do
      refute AutoRejectCap.exhausted?(nil)
    end

    test "is false below the limit" do
      media_item = media_item_fixture()
      burn(media_item.id, 2)

      refute AutoRejectCap.exhausted?(media_item.id)
    end

    test "is true once the limit is reached" do
      media_item = media_item_fixture()
      burn(media_item.id, 3)

      assert AutoRejectCap.exhausted?(media_item.id)
    end
  end

  describe "exhausted_ids/1" do
    test "returns only the capped ids" do
      capped = media_item_fixture()
      open = media_item_fixture()
      burn(capped.id, 3)
      burn(open.id, 1)

      assert AutoRejectCap.exhausted_ids([capped.id, open.id, nil]) == MapSet.new([capped.id])
    end

    test "returns an empty set for no ids" do
      assert AutoRejectCap.exhausted_ids([]) == MapSet.new()
    end
  end
end
