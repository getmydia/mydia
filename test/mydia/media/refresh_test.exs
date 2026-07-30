defmodule Mydia.Media.RefreshTest do
  use Mydia.DataCase, async: false

  alias Mydia.Media.MediaItem
  alias Mydia.Media.Refresh
  alias Mydia.Metadata.Structs.MediaMetadata

  # MediaMetadata enforces :provider_id, :provider and :media_type, so every
  # literal needs them. Default provider_id to "" (which is what
  # MetadataType.map_to_struct/1 stores when there is no id) so tests that care
  # about `id` are not silently satisfied by `provider_id`.
  defp metadata(attrs) do
    defaults = %{provider_id: "", provider: :metadata_relay, media_type: :movie}
    struct!(MediaMetadata, Map.merge(defaults, Map.new(attrs)))
  end

  describe "resolve_provider/1" do
    test "metadata_source :tmdb wins over a back-filled tvdb_id" do
      item = %MediaItem{metadata_source: :tmdb, tmdb_id: 111, tvdb_id: 222}
      assert Refresh.resolve_provider(item) == {111, :tmdb}
    end

    test "metadata_source :tvdb wins over a present tmdb_id" do
      item = %MediaItem{metadata_source: :tvdb, tmdb_id: 111, tvdb_id: 222}
      assert Refresh.resolve_provider(item) == {222, :tvdb}
    end

    test "without metadata_source, tvdb_id takes legacy precedence" do
      item = %MediaItem{metadata_source: nil, tmdb_id: 111, tvdb_id: 222}
      assert Refresh.resolve_provider(item) == {222, :tvdb}
    end

    test "falls back to tmdb_id when no tvdb_id is present" do
      item = %MediaItem{metadata_source: nil, tmdb_id: 111, tvdb_id: nil}
      assert Refresh.resolve_provider(item) == {111, :tmdb}
    end

    # REGRESSION: this is the exact shape that raised in
    # metadata_refresh.ex:306 via `media_item.metadata["id"]`.
    # provider_id is deliberately different so this proves `id` is read and wins.
    test "falls back to metadata.id when both provider id columns are nil" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: 12_345, provider_id: "999")
      }

      assert Refresh.resolve_provider(item) == {12_345, :tmdb}
    end

    test "parses a string metadata.id" do
      item = %MediaItem{tmdb_id: nil, tvdb_id: nil, metadata: metadata(id: "678")}
      assert Refresh.resolve_provider(item) == {678, :tmdb}
    end

    test "falls back to metadata.provider_id when metadata.id is nil" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: nil, provider_id: "999")
      }

      assert Refresh.resolve_provider(item) == {999, :tmdb}
    end

    # MetadataType.map_to_struct/1 sets provider_id to `to_string(data[:id] || "")`,
    # so an empty string is common — and truthy in Elixir.
    test "an empty provider_id resolves to no provider, not a bogus id" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: nil, provider_id: "")
      }

      assert Refresh.resolve_provider(item) == {nil, nil}
    end

    test "an unparseable metadata id resolves to no provider" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: "abc", provider_id: "xyz")
      }

      assert Refresh.resolve_provider(item) == {nil, nil}
    end

    test "nil metadata resolves to no provider" do
      item = %MediaItem{tmdb_id: nil, tvdb_id: nil, metadata: nil}
      assert Refresh.resolve_provider(item) == {nil, nil}
    end

    test "a legacy plain-map metadata resolves to no provider instead of raising" do
      item = %MediaItem{tmdb_id: nil, tvdb_id: nil, metadata: %{"id" => 5}}
      assert Refresh.resolve_provider(item) == {nil, nil}
    end
  end
end
