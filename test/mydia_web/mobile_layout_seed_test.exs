defmodule MydiaWeb.MobileLayoutSeedTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  test "returns ids for every manifest path key and seeds awkward data" do
    admin = admin_user_fixture()
    ids = MydiaWeb.MobileLayoutSeed.insert!(admin)

    assert Map.keys(ids) |> Enum.sort() == [:collection, :movie, :section, :show]
    assert Repo.get!(Mydia.Media.MediaItem, ids.movie).title =~ "Salt Meridian"
    assert Repo.aggregate(Mydia.Downloads.Download, :count) >= 7
    assert Repo.aggregate(Mydia.Media.Episode, :count) >= 6
  end

  test "seeds one download per Issues kind" do
    MydiaWeb.MobileLayoutSeed.insert!(admin_user_fixture())
    downloads = Repo.all(Mydia.Downloads.Download)

    assert Enum.count(downloads, &(&1.import_failed_at != nil)) >= 2
    assert Enum.any?(downloads, &(&1.removal_error != nil))
    assert Enum.any?(downloads, &(&1.match_status == "unresolved_files"))
    assert Enum.any?(downloads, &(&1.import_failure_reason == "no_client"))
  end
end
