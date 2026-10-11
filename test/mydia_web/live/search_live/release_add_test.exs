defmodule MydiaWeb.SearchLive.ReleaseAddTest do
  # The metadata stub registry is global.
  use Mydia.DataCase, async: false

  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.Library.ReleaseParser
  alias MydiaWeb.SearchLive.ReleaseAdd

  setup :setup_metadata_stub

  test "the chosen type rescues a release the parser cannot classify" do
    title = "invented readme"
    assert ReleaseParser.parse(title).type == :unknown

    refute ReleaseAdd.add_release_to_library(Scope.unrestricted(), title, :movie, nil) ==
             {:error, :parse_failed}
  end
end
