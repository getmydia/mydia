defmodule MydiaWeb.RequestAccess.CoreMatrixTest do
  @moduledoc """
  Guests with different age limits against one fictional catalog: who sees
  which Discover card, who can file which request, and what each guest's
  library shows once an admin approves.
  """

  # async: false: the catalog swaps :metadata_relay_url and writes the shared
  # metadata cache, and connected LiveViews read the DB from their own process.
  use MydiaWeb.ConnCase, async: false

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
end
