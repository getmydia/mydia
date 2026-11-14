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

  describe "torrent_files/3 and set_file_selection/4" do
    test "return :unsupported for an adapter without the callbacks" do
      assert {:error, :unsupported} = Client.torrent_files(ListFilesStubWithout, %{}, "abc")

      assert {:error, :unsupported} =
               Client.set_file_selection(ListFilesStubWithout, %{}, "abc", [0])
    end

    test "nil adapter gives a descriptive error" do
      assert {:error, %Mydia.Downloads.Client.Error{}} = Client.torrent_files(nil, %{}, "abc")

      assert {:error, %Mydia.Downloads.Client.Error{}} =
               Client.set_file_selection(nil, %{}, "abc", [0])
    end

    test "supports_file_selection?/1" do
      refute Client.supports_file_selection?(nil)
      refute Client.supports_file_selection?(ListFilesStubWithout)
      assert Client.supports_file_selection?(Mydia.Downloads.Client.Rqbit)
    end
  end
end
