defmodule Mydia.Downloads.ExternalPolicyTest do
  @moduledoc """
  The whole opt-out rule for torrents Mydia did not add.

  `:auto` is a resolved default rather than a stored one: a client that gains
  a category later tightens on its own, which is the behaviour agreed for
  issue #531. Everything else is an explicit operator choice and is returned
  unchanged.
  """
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ExternalPolicy
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Settings.DownloadClientConfig

  defp config(overrides \\ %{}) do
    struct!(
      %DownloadClientConfig{
        name: "qbit",
        type: :qbittorrent,
        external_torrents: :auto,
        category: nil,
        categories: %{}
      },
      overrides
    )
  end

  defp status(categories \\ []) do
    %DownloadStatus{
      id: "hash-a",
      name: "Dune.Part.Two.2024.2160p.WEB-DL.x265-GROUP",
      state: :seeding,
      progress: 100.0,
      categories: categories
    }
  end

  describe "configured_categories/1" do
    test "is empty when neither the map nor the legacy field is set" do
      assert MapSet.size(ExternalPolicy.configured_categories(config())) == 0
    end

    test "reads the legacy single category" do
      assert ExternalPolicy.configured_categories(config(%{category: "mydia"})) ==
               MapSet.new(["mydia"])
    end

    test "reads the per-content-type map" do
      cfg = config(%{categories: %{"movie" => "mydia-movies", "tv" => "mydia-tv"}})

      assert ExternalPolicy.configured_categories(cfg) ==
               MapSet.new(["mydia-movies", "mydia-tv"])
    end

    test "unions the map with the legacy field" do
      cfg = config(%{category: "mydia", categories: %{"movie" => "mydia-movies"}})

      assert ExternalPolicy.configured_categories(cfg) ==
               MapSet.new(["mydia", "mydia-movies"])
    end

    test "drops blank and whitespace-only values" do
      cfg = config(%{category: "   ", categories: %{"movie" => "", "tv" => "mydia-tv"}})

      assert ExternalPolicy.configured_categories(cfg) == MapSet.new(["mydia-tv"])
    end

    test "trims surrounding whitespace so a stray space cannot silence a client" do
      assert ExternalPolicy.configured_categories(config(%{category: " mydia "})) ==
               MapSet.new(["mydia"])
    end
  end

  describe "supports_categories?/1" do
    test "true for qbittorrent and transmission" do
      assert ExternalPolicy.supports_categories?(:qbittorrent)
      assert ExternalPolicy.supports_categories?(:transmission)
    end

    test "false for rqbit, which has no categories or labels" do
      refute ExternalPolicy.supports_categories?(:rqbit)
    end

    test "false for an unknown type" do
      refute ExternalPolicy.supports_categories?(:not_a_client)
    end
  end

  describe "effective_mode/1 resolving :auto" do
    test "resolves to :adopt when no category is configured" do
      assert ExternalPolicy.effective_mode(config()) == :adopt
    end

    test "resolves to :category_only when a legacy category is configured" do
      assert ExternalPolicy.effective_mode(config(%{category: "mydia"})) == :category_only
    end

    test "resolves to :category_only when the categories map is populated" do
      cfg = config(%{categories: %{"movie" => "mydia-movies"}})

      assert ExternalPolicy.effective_mode(cfg) == :category_only
    end

    test "resolves to :adopt for rqbit even with a category configured" do
      cfg = config(%{type: :rqbit, category: "mydia"})

      assert ExternalPolicy.effective_mode(cfg) == :adopt
    end

    test "resolves to :adopt when the only configured category is blank" do
      assert ExternalPolicy.effective_mode(config(%{category: ""})) == :adopt
    end

    test "treats a nil mode as :auto, so a struct built without the field still resolves" do
      assert ExternalPolicy.effective_mode(config(%{external_torrents: nil})) == :adopt
    end
  end

  describe "effective_mode/1 with an explicit mode" do
    test "returns each explicit mode unchanged" do
      for mode <- [:adopt, :category_only, :ignore] do
        cfg = config(%{external_torrents: mode, category: "mydia"})

        assert ExternalPolicy.effective_mode(cfg) == mode
      end
    end

    test "an explicit mode wins over what :auto would have chosen" do
      # A category is configured, so :auto would say :category_only.
      cfg = config(%{external_torrents: :adopt, category: "mydia"})

      assert ExternalPolicy.effective_mode(cfg) == :adopt
    end
  end

  describe "decide/2" do
    test "adopts everything in :adopt mode, category or not" do
      cfg = config(%{external_torrents: :adopt})

      assert ExternalPolicy.decide(cfg, status()) == :adopt
      assert ExternalPolicy.decide(cfg, status(["someone-elses"])) == :adopt
    end

    test "refuses everything in :ignore mode, even a matching category" do
      cfg = config(%{external_torrents: :ignore, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status(["mydia"])) == :excluded_by_ignore
    end

    test "adopts a torrent carrying the configured category" do
      cfg = config(%{external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status(["mydia"])) == :adopt
    end

    test "adopts when any one of several labels matches" do
      cfg = config(%{external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status(["seeding", "mydia"])) == :adopt
    end

    test "refuses a torrent carrying a different category" do
      cfg = config(%{external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status(["manual"])) == :excluded_by_category
    end

    test "refuses a torrent carrying no category at all" do
      cfg = config(%{external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status([])) == :excluded_by_category
    end

    test "category matching is exact, not a prefix or substring" do
      cfg = config(%{external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status(["mydia-movies"])) == :excluded_by_category
    end

    test "fails closed on a client that cannot report categories" do
      # Validation blocks this combination at write time. If one ever reaches
      # the runtime anyway, refusing is the safe residual behaviour: rqbit
      # reports no categories, so nothing could legitimately match.
      cfg = config(%{type: :rqbit, external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.decide(cfg, status([])) == :excluded_by_category
    end

    test "tolerates a status struct with no categories field populated" do
      cfg = config(%{external_torrents: :category_only, category: "mydia"})
      bare = %DownloadStatus{id: "h", name: "n", state: :seeding, progress: 1.0}

      assert ExternalPolicy.decide(cfg, bare) == :excluded_by_category
    end
  end

  describe "adopt?/2" do
    test "is true only for the :adopt decision" do
      adopting = config(%{external_torrents: :adopt})
      ignoring = config(%{external_torrents: :ignore})
      scoped = config(%{external_torrents: :category_only, category: "mydia"})

      assert ExternalPolicy.adopt?(adopting, status())
      refute ExternalPolicy.adopt?(ignoring, status())
      assert ExternalPolicy.adopt?(scoped, status(["mydia"]))
      refute ExternalPolicy.adopt?(scoped, status(["other"]))
    end
  end
end
