defmodule MydiaWeb.Live.Helpers.PersonModalTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts.Scope
  alias Mydia.Media.RemoteSignals
  alias Mydia.Metadata.Structs.{Person, PersonCredit}
  alias MydiaWeb.Live.Helpers.PersonModal

  defp person(movie_ids, show_ids) do
    %Person{
      tmdb_id: 1,
      name: "Test Person",
      movie_credits: Enum.map(movie_ids, &credit(&1, :movie)),
      tv_credits: Enum.map(show_ids, &credit(&1, :tv_show))
    }
  end

  defp credit(id, type),
    do: %PersonCredit{tmdb_id: id, media_type: type, title: "Title #{id}", year: 2020}

  describe "open/close/handle_result" do
    defp host_socket do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          metadata_config: %{type: :metadata_relay, base_url: "http://localhost:1", options: %{}},
          current_scope: Scope.unrestricted()
        }
      }
      |> PersonModal.init()
    end

    test "open ignores params without an id or with a bad id" do
      socket = host_socket()
      assert PersonModal.open(socket, %{"name" => "x"}) == socket
      assert PersonModal.open(socket, %{"id" => "abc"}) == socket
    end

    test "a result landing after close does not reopen the dialog" do
      socket =
        host_socket()
        |> PersonModal.open(%{"id" => "1", "name" => "Test Person"})
        |> PersonModal.close()
        |> PersonModal.handle_result({:ok, {:ok, person([], [])}})

      assert socket.assigns.selected_person == nil
      assert socket.assigns.person_stub == nil
    end

    test "a stale result for another person is ignored" do
      socket =
        host_socket()
        |> PersonModal.open(%{"id" => "2", "name" => "Other"})
        |> PersonModal.handle_result({:ok, {:ok, person([], [])}})

      assert socket.assigns.selected_person == nil
      assert socket.assigns.person_loading
    end
  end

  describe "enrich_titles/2" do
    test "library status is per media type when a movie and a show share an id" do
      media_item_fixture(%{type: "movie", tmdb_id: 500})

      titles = PersonModal.enrich_titles(person([500], [500]), Scope.unrestricted())

      assert [%{media_type: :movie, in_library: true}, %{media_type: :tv_show, in_library: false}] =
               titles
    end

    test "a restricted scope drops titles the remote filter refuses" do
      scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))
      ok_id = unique_provider_id()
      bad_id = unique_provider_id()

      warm_remote_signals({:tmdb, ok_id}, :movie, %RemoteSignals{
        content_rating: "PG",
        age: 8,
        category: "movie"
      })

      warm_remote_signals({:tmdb, bad_id}, :movie, %RemoteSignals{
        content_rating: "R",
        age: 17,
        category: "movie"
      })

      titles = PersonModal.enrich_titles(person([ok_id, bad_id], []), scope)

      assert Enum.map(titles, & &1.provider_id) == [Integer.to_string(ok_id)]
    end
  end
end
