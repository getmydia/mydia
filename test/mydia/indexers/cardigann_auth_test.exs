defmodule Mydia.Indexers.CardigannAuthTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.CardigannAuth
  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Repo

  describe "session store" do
    setup do
      definition =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "invented-tracker",
          name: "Invented Tracker",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "id: invented-tracker",
          schema_version: "v11"
        })

      {:ok, definition: definition}
    end

    test "store_session/3 keeps exactly one row per definition", %{definition: d} do
      {:ok, _} = CardigannAuth.store_session(d.id, ["a=1"])
      {:ok, _} = CardigannAuth.store_session(d.id, ["a=2"])

      assert Repo.aggregate(CardigannSearchSession, :count) == 1
      assert {:ok, %{cookies: ["a=2"]}} = CardigannAuth.get_stored_session(d.id)
    end

    test "a session without expiry never expires", %{definition: d} do
      {:ok, _} = CardigannAuth.store_session(d.id, ["a=1"], nil)
      assert {:ok, %{expires_at: nil}} = CardigannAuth.get_stored_session(d.id)
    end

    test "invalidate_session/1 removes the row", %{definition: d} do
      {:ok, _} = CardigannAuth.store_session(d.id, ["a=1"])
      assert :ok = CardigannAuth.invalidate_session(d.id)
      assert {:error, :not_found} = CardigannAuth.get_stored_session(d.id)
    end

    test "invalidate_session/2 removes the row only while it holds those cookies", %{
      definition: d
    } do
      {:ok, _} = CardigannAuth.store_session(d.id, ["a=2"])
      assert :ok = CardigannAuth.invalidate_session(d.id, ["a=1"])
      assert {:ok, %{cookies: ["a=2"]}} = CardigannAuth.get_stored_session(d.id)

      assert :ok = CardigannAuth.invalidate_session(d.id, ["a=2"])
      assert {:error, :not_found} = CardigannAuth.get_stored_session(d.id)
    end
  end

  describe "get_stored_session/1 and store_session/3" do
    test "stores and retrieves session cookies" do
      cardigann_def =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "test-storage",
          name: "Test",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "",
          schema_version: "11"
        })

      cookies = ["session=secret123", "uid=456"]
      expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, stored} =
               CardigannAuth.store_session(cardigann_def.id, cookies, expires_at)

      assert stored.cardigann_definition_id == cardigann_def.id

      # Verify cookies are stored directly as a list
      assert is_list(stored.cookies)
      assert stored.cookies == cookies

      # Retrieve and verify
      assert {:ok, retrieved} = CardigannAuth.get_stored_session(cardigann_def.id)
      assert retrieved.cookies == cookies
      # Allow for slight timing differences in DateTime comparison
      assert_in_delta DateTime.to_unix(retrieved.expires_at), DateTime.to_unix(expires_at), 1
    end

    test "returns :not_found when no session exists" do
      non_existent_id = Ecto.UUID.generate()
      assert {:error, :not_found} = CardigannAuth.get_stored_session(non_existent_id)
    end

    test "returns :expired for expired sessions" do
      cardigann_def =
        Repo.insert!(%Mydia.Indexers.CardigannDefinition{
          indexer_id: "test-expired",
          name: "Test",
          type: "private",
          links: %{},
          capabilities: %{},
          definition: "",
          schema_version: "11"
        })

      cookies = ["session=old"]
      expires_at = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert {:ok, _stored} =
               CardigannAuth.store_session(cardigann_def.id, cookies, expires_at)

      assert {:error, :expired} = CardigannAuth.get_stored_session(cardigann_def.id)
    end
  end
end
