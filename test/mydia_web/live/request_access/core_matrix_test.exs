defmodule MydiaWeb.RequestAccess.CoreMatrixTest do
  @moduledoc """
  Guests with different age limits against one fictional catalog: who sees
  which Discover card, who can file which request, and what each guest's
  library shows once an admin approves.
  """

  # async: false: the catalog swaps :metadata_relay_url and writes the shared
  # metadata cache, and connected LiveViews read the DB from their own process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.RequestAccessCatalog

  setup %{conn: conn} do
    world = seed!()
    %{world: world, t: world.titles, cast: cast!(conn)}
  end

  describe "visibility" do
    test "each guest sees exactly the cards within their limit", %{t: t, cast: cast} do
      limits = %{kid: 7, teen: 14, adult: nil}

      for {who_key, limit} <- limits, {_key, title} <- t do
        expected =
          case {limit, age(title)} do
            {nil, _} -> true
            {_limit, nil} -> false
            {limit, age} -> age <= limit
          end

        assert discover_card?(cast[who_key], title) == expected,
               "#{who_key} (limit #{inspect(limit)}) on #{title.name} (#{inspect(title.certification)}): expected visible=#{expected}"
      end
    end
  end

  describe "requests above a guest's limit" do
    test "a forged Discover event for a hidden card stores nothing", %{t: t, cast: cast} do
      forge_request(cast.kid, t.pg_movie)
      forge_request(cast.teen, t.r_movie)
      forge_request(cast.teen, t.ma_show)

      # Paired positive: the same guest can request what they can see.
      assert request!(cast.kid, t.g_movie).status == "pending"
    end

    test "the context refuses them as :restricted", %{t: t, cast: cast, world: world} do
      assert {:error, :restricted} = create_as(cast.kid, t.pg_movie, world)
      assert {:error, :restricted} = create_as(cast.teen, t.r_movie, world)
      assert {:error, :restricted} = create_as(cast.teen, t.ma_show, world)
      assert {:error, :restricted} = create_as(cast.teen, t.unrated_movie, world)

      assert {:ok, _} = create_as(cast.teen, t.pg13_movie, world)
    end
  end

  describe "round trip" do
    test "each guest's library holds exactly the approved titles within their limit",
         %{t: t, cast: cast} do
      kid_g = request!(cast.kid, t.g_movie)
      teen_pg13 = request!(cast.teen, t.pg13_movie)
      teen_show = request!(cast.teen, t.pg_show)
      adult_r = request!(cast.adult, t.r_movie)

      requests = [kid_g, teen_pg13, teen_show, adult_r]

      {:ok, queue, _html} = live(cast.admin.conn, ~p"/admin/requests")

      for r <- requests do
        assert has_element?(queue, "#request-#{r.id}")
      end

      assert Enum.sort(my_request_ids(cast.kid)) == [kid_g.id]
      assert Enum.sort(my_request_ids(cast.teen)) == Enum.sort([teen_pg13.id, teen_show.id])
      assert Enum.sort(my_request_ids(cast.adult)) == [adult_r.id]

      for r <- requests, do: approve!(cast.admin, r)

      approved = [t.g_movie, t.pg13_movie, t.pg_show, t.r_movie]

      expected = %{
        kid: [t.g_movie],
        teen: [t.g_movie, t.pg13_movie, t.pg_show],
        adult: approved
      }

      for {who_key, visible} <- expected, title <- approved do
        assert sees_in_library?(cast[who_key], title) == title in visible,
               "#{who_key} on #{title.name}: expected visible=#{title in visible}"
      end
    end
  end
end
