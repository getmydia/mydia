defmodule MydiaWeb.OperationErrorsTest do
  use ExUnit.Case, async: true

  alias Mydia.Logger, as: MydiaLogger
  alias MydiaWeb.OperationErrors

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  @operations ~w(update_setting save_quality_profile delete_quality_profile
                 duplicate_quality_profile save_download_client delete_download_client
                 test_download_client save_indexer delete_indexer test_indexer
                 remove_library_indexer save_library_path delete_library_path
                 toggle_library_indexer)a

  defp changeset do
    {%{}, %{name: :string}}
    |> Ecto.Changeset.cast(%{}, [:name])
    |> Ecto.Changeset.add_error(:name, "can't be blank")
  end

  test "matches the domain text for every operation and failure shape" do
    errors = [
      {:error, :profile_in_use},
      {:error, :not_found},
      {:error, :some_reason},
      {:error, "a plain string"},
      :multiple_failures,
      %{message: "boom"},
      :unrecognized,
      changeset()
    ]

    for operation <- @operations, error <- errors do
      assert OperationErrors.user_error_message(operation, error) ==
               MydiaLogger.user_error_message(operation, error)
    end
  end

  test "an empty changeset asks for a second look at the input" do
    changeset = Ecto.Changeset.change({%{}, %{}})

    assert OperationErrors.user_error_message(:save_indexer, changeset) ==
             MydiaLogger.user_error_message(:save_indexer, changeset)
  end

  test "restricted_message matches the domain text" do
    assert OperationErrors.restricted_message() == Mydia.Media.restricted_message()
  end
end
