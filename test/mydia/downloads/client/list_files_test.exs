defmodule Mydia.Downloads.Client.ListFilesStubWithout do
  @moduledoc false
  # Deliberately does NOT implement list_files/2.
  def get_status(_config, _client_id), do: {:ok, %{}}
end

defmodule Mydia.Downloads.Client.ListFilesStubWith do
  @moduledoc false
  def list_files(_config, "known"), do: {:ok, ["/downloads/Movie/movie.mkv"]}
  def list_files(_config, _other), do: {:error, :nope}
end

defmodule Mydia.Downloads.ClientListFilesTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.ListFilesStubWith
  alias Mydia.Downloads.Client.ListFilesStubWithout

  describe "list_files/3" do
    test "returns :unsupported for an adapter that does not implement the callback" do
      assert {:error, :unsupported} = Client.list_files(ListFilesStubWithout, %{}, "abc")
    end

    test "dispatches to an adapter that does implement the callback" do
      assert {:ok, ["/downloads/Movie/movie.mkv"]} =
               Client.list_files(ListFilesStubWith, %{}, "known")
    end

    test "passes an adapter error straight through" do
      assert {:error, :nope} = Client.list_files(ListFilesStubWith, %{}, "other")
    end

    test "returns a descriptive error for a nil adapter" do
      assert {:error, %Mydia.Downloads.Client.Error{}} = Client.list_files(nil, %{}, "abc")
    end
  end
end
