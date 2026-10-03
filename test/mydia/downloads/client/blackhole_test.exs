defmodule Mydia.Downloads.Client.BlackholeTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Blackhole

  @sample_torrent_hash "ABC123DEF456789012345678901234567890ABCD"

  # Minimal bencode-encoded torrent file for testing
  # This encodes: %{"info" => %{"name" => "test", "piece length" => 16384, "pieces" => ""}}
  @sample_torrent_file "d4:infod4:name4:test12:piece lengthi16384e6:pieces0:ee"

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      behaviours = Blackhole.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "test_connection/1" do
    @tag :tmp_dir
    test "succeeds when both folders exist and are accessible", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, client_info} = Blackhole.test_connection(config)
      assert client_info.version == "1.0.0"
      assert client_info.api_version == "filesystem"
    end

    @tag :tmp_dir
    test "fails when watch_folder doesn't exist", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "nonexistent_watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:error, error} = Blackhole.test_connection(config)
      assert error.type == :invalid_config
      assert error.message =~ "does not exist"
    end

    @tag :tmp_dir
    test "fails when completed_folder doesn't exist", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "nonexistent_completed")
      File.mkdir_p!(watch_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:error, error} = Blackhole.test_connection(config)
      assert error.type == :invalid_config
      assert error.message =~ "does not exist"
    end

    test "fails when watch_folder is missing from config" do
      config = %{
        connection_settings: %{
          "completed_folder" => "/some/path"
        }
      }

      assert {:error, error} = Blackhole.test_connection(config)
      assert error.type == :invalid_config
      assert error.message =~ "Watch folder is required"
    end

    test "fails when completed_folder is missing from config" do
      config = %{
        connection_settings: %{
          "watch_folder" => "/some/path"
        }
      }

      assert {:error, error} = Blackhole.test_connection(config)
      assert error.type == :invalid_config
      assert error.message =~ "Completed folder is required"
    end

    test "fails when connection_settings is empty" do
      config = %{connection_settings: %{}}

      assert {:error, error} = Blackhole.test_connection(config)
      assert error.type == :invalid_config
    end
  end

  describe "add_torrent/3" do
    @tag :tmp_dir
    test "writes torrent file to watch folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, hash} = Blackhole.add_torrent(config, {:file, @sample_torrent_file})
      assert is_binary(hash)

      # Verify file was written
      files = File.ls!(watch_folder)
      assert length(files) == 1
      [written_file] = files
      assert String.ends_with?(written_file, ".torrent")
    end

    @tag :tmp_dir
    test "creates category subfolder when configured", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder,
          "use_category_subfolders" => true
        }
      }

      assert {:ok, _hash} =
               Blackhole.add_torrent(config, {:file, @sample_torrent_file}, category: "movies")

      # Verify category subfolder was created
      category_folder = Path.join(watch_folder, "movies")
      assert File.dir?(category_folder)

      files = File.ls!(category_folder)
      assert length(files) == 1
    end

    @tag :tmp_dir
    test "creates category subfolder when the form saved the string \"true\"", %{
      tmp_dir: tmp_dir
    } do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # connection_settings is a plain :map, so the admin form stores strings.
      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder,
          "use_category_subfolders" => "true"
        }
      }

      assert {:ok, _hash} =
               Blackhole.add_torrent(config, {:file, @sample_torrent_file}, category: "movies")

      assert File.dir?(Path.join(watch_folder, "movies"))
    end

    @tag :tmp_dir
    test "handles magnet links by writing .magnet file", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      magnet = "magnet:?xt=urn:btih:#{@sample_torrent_hash}&dn=test"

      assert {:ok, hash} = Blackhole.add_torrent(config, {:magnet, magnet})
      assert hash == @sample_torrent_hash

      # Verify .magnet file was written
      files = File.ls!(watch_folder)
      assert length(files) == 1
      [written_file] = files
      assert String.ends_with?(written_file, ".magnet")
    end

    @tag :tmp_dir
    test "returns unique client_id (hash)", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      magnet = "magnet:?xt=urn:btih:#{@sample_torrent_hash}&dn=test"

      assert {:ok, hash} = Blackhole.add_torrent(config, {:magnet, magnet})
      assert is_binary(hash)
      assert String.length(hash) == 40
    end

    @tag :tmp_dir
    test "silently ignores priority option (filesystem drop has no queue)",
         %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        },
        priority_profile: %{"high" => "this-would-error-if-blackhole-used-it"}
      }

      assert {:ok, _hash} =
               Blackhole.add_torrent(config, {:file, @sample_torrent_file}, priority: :high)

      # File still landed in the watch folder; no priority side effect.
      assert length(File.ls!(watch_folder)) == 1
    end
  end

  describe "get_status/2" do
    @tag :tmp_dir
    test "finds a pending torrent in a category subfolder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder,
          "use_category_subfolders" => "true"
        }
      }

      assert {:ok, hash} =
               Blackhole.add_torrent(config, {:file, @sample_torrent_file}, category: "movies")

      assert {:ok, status} = Blackhole.get_status(config, hash)
      assert status.state == :downloading
    end

    @tag :tmp_dir
    test "returns pending state when torrent file exists in watch_folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create a torrent file
      torrent_file = Path.join(watch_folder, "#{@sample_torrent_hash}.torrent")
      File.write!(torrent_file, @sample_torrent_file)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, status} = Blackhole.get_status(config, @sample_torrent_hash)
      assert status.state == :downloading
      assert status.progress == 0.0
      assert status.id == @sample_torrent_hash
    end

    @tag :tmp_dir
    test "returns completed state when folder exists in completed_folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create a completed download folder (containing the hash in the name)
      download_folder = Path.join(completed_folder, "#{@sample_torrent_hash}-TestDownload")
      File.mkdir_p!(download_folder)
      # Add a file inside
      File.write!(Path.join(download_folder, "video.mkv"), "fake video content")

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, status} = Blackhole.get_status(config, @sample_torrent_hash)
      assert status.state == :completed
      assert status.progress == 100.0
    end

    @tag :tmp_dir
    test "returns not_found error when no match", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:error, error} = Blackhole.get_status(config, "NONEXISTENT123")
      assert error.type == :not_found
    end

    @tag :tmp_dir
    test "completed takes priority over pending", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create both pending torrent file and completed folder
      torrent_file = Path.join(watch_folder, "#{@sample_torrent_hash}.torrent")
      File.write!(torrent_file, @sample_torrent_file)

      download_folder = Path.join(completed_folder, "#{@sample_torrent_hash}-TestDownload")
      File.mkdir_p!(download_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, status} = Blackhole.get_status(config, @sample_torrent_hash)
      # Completed should take priority
      assert status.state == :completed
    end
  end

  describe "list_torrents/2" do
    @tag :tmp_dir
    test "lists pending torrents from category subfolders", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder,
          "use_category_subfolders" => "true"
        }
      }

      assert {:ok, hash} =
               Blackhole.add_torrent(config, {:file, @sample_torrent_file}, category: "movies")

      assert {:ok, torrents} = Blackhole.list_torrents(config)
      assert Enum.any?(torrents, &(&1.id == hash))
    end

    @tag :tmp_dir
    test "lists pending torrents from watch folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create multiple torrent files
      File.write!(Path.join(watch_folder, "hash1.torrent"), "content1")
      File.write!(Path.join(watch_folder, "hash2.torrent"), "content2")

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, torrents} = Blackhole.list_torrents(config)
      assert length(torrents) == 2

      pending = Enum.filter(torrents, &(&1.state == :downloading))
      assert length(pending) == 2
    end

    @tag :tmp_dir
    test "lists completed downloads from completed folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create completed download folders
      folder1 = Path.join(completed_folder, "Download1")
      folder2 = Path.join(completed_folder, "Download2")
      File.mkdir_p!(folder1)
      File.mkdir_p!(folder2)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, torrents} = Blackhole.list_torrents(config)
      assert length(torrents) == 2

      completed = Enum.filter(torrents, &(&1.state == :completed))
      assert length(completed) == 2
    end

    @tag :tmp_dir
    test "filters work correctly", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create pending and completed
      File.write!(Path.join(watch_folder, "pending.torrent"), "content")
      File.mkdir_p!(Path.join(completed_folder, "CompletedDownload"))

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      # All torrents
      assert {:ok, all} = Blackhole.list_torrents(config)
      assert length(all) == 2

      # Downloading only
      assert {:ok, downloading} = Blackhole.list_torrents(config, filter: :downloading)
      assert length(downloading) == 1
      assert hd(downloading).state == :downloading

      # Completed only
      assert {:ok, completed} = Blackhole.list_torrents(config, filter: :completed)
      assert length(completed) == 1
      assert hd(completed).state == :completed
    end

    @tag :tmp_dir
    test "empty folders return empty list", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, torrents} = Blackhole.list_torrents(config)
      assert torrents == []
    end
  end

  describe "remove_torrent/3" do
    @tag :tmp_dir
    test "removes a torrent from a category subfolder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder,
          "use_category_subfolders" => "true"
        }
      }

      assert {:ok, hash} =
               Blackhole.add_torrent(config, {:file, @sample_torrent_file}, category: "movies")

      assert :ok = Blackhole.remove_torrent(config, hash)
      assert File.ls!(Path.join(watch_folder, "movies")) == []
    end

    @tag :tmp_dir
    test "removes torrent file from watch_folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create a torrent file
      torrent_file = Path.join(watch_folder, "#{@sample_torrent_hash}.torrent")
      File.write!(torrent_file, @sample_torrent_file)
      assert File.exists?(torrent_file)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert :ok = Blackhole.remove_torrent(config, @sample_torrent_hash)
      refute File.exists?(torrent_file)
    end

    @tag :tmp_dir
    test "removes completed download when delete_files is true", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create a completed download folder
      download_folder = Path.join(completed_folder, "#{@sample_torrent_hash}-TestDownload")
      File.mkdir_p!(download_folder)
      File.write!(Path.join(download_folder, "video.mkv"), "content")
      assert File.exists?(download_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert :ok = Blackhole.remove_torrent(config, @sample_torrent_hash, delete_files: true)
      refute File.exists?(download_folder)
    end

    @tag :tmp_dir
    test "keeps completed download when delete_files is false", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create a completed download folder
      download_folder = Path.join(completed_folder, "#{@sample_torrent_hash}-TestDownload")
      File.mkdir_p!(download_folder)
      File.write!(Path.join(download_folder, "video.mkv"), "content")

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert :ok = Blackhole.remove_torrent(config, @sample_torrent_hash, delete_files: false)
      # Folder should still exist
      assert File.exists?(download_folder)
    end

    @tag :tmp_dir
    test "succeeds even when torrent doesn't exist", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert :ok = Blackhole.remove_torrent(config, "NONEXISTENT123")
    end
  end

  describe "pause_torrent/2" do
    @tag :tmp_dir
    test "returns not supported error", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:error, error} = Blackhole.pause_torrent(config, @sample_torrent_hash)
      assert error.type == :api_error
      assert error.message =~ "not supported"
    end
  end

  describe "resume_torrent/2" do
    @tag :tmp_dir
    test "returns not supported error", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:error, error} = Blackhole.resume_torrent(config, @sample_torrent_hash)
      assert error.type == :api_error
      assert error.message =~ "not supported"
    end
  end

  describe "completed status details" do
    @tag :tmp_dir
    test "calculates folder size correctly", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      # Create a completed download with known file sizes
      download_folder = Path.join(completed_folder, "#{@sample_torrent_hash}-TestDownload")
      File.mkdir_p!(download_folder)
      File.write!(Path.join(download_folder, "file1.txt"), String.duplicate("a", 1000))
      File.write!(Path.join(download_folder, "file2.txt"), String.duplicate("b", 500))

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, status} = Blackhole.get_status(config, @sample_torrent_hash)
      # Total size should be 1500 bytes
      assert status.size == 1500
      assert status.downloaded == 1500
    end

    @tag :tmp_dir
    test "returns save_path pointing to completed folder", %{tmp_dir: tmp_dir} do
      watch_folder = Path.join(tmp_dir, "watch")
      completed_folder = Path.join(tmp_dir, "completed")
      File.mkdir_p!(watch_folder)
      File.mkdir_p!(completed_folder)

      download_folder = Path.join(completed_folder, "#{@sample_torrent_hash}-TestDownload")
      File.mkdir_p!(download_folder)

      config = %{
        connection_settings: %{
          "watch_folder" => watch_folder,
          "completed_folder" => completed_folder
        }
      }

      assert {:ok, status} = Blackhole.get_status(config, @sample_torrent_hash)
      assert status.save_path == download_folder
    end
  end
end
