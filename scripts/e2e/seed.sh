#!/bin/sh
# Seeds the E2E test environment: admin user, remote access, test media.
# Runs inside the mydia container after the app reports healthy.
#
# Extracted from the former Dockerfile.e2e heredoc. Unlike that version this
# script fails loudly: a seed that half-succeeds used to surface much later as
# an unexplained Dart test failure.
set -eu

ADMIN_EMAIL="${E2E_ADMIN_EMAIL:-admin@test.local}"
ADMIN_PASSWORD="${E2E_ADMIN_PASSWORD:-testpassword123}"
VIDEO_PATH="/media/movies/e2e-test-video.mp4"
SCRIPT_DIR="$(dirname "$0")"

echo "E2E: creating admin user $ADMIN_EMAIL"
su-exec mydia /app/bin/mydia rpc "
    case Mydia.Accounts.get_user_by_email(\"$ADMIN_EMAIL\") do
        nil ->
            case Mydia.Accounts.create_user(%{
                username: \"e2e_admin\",
                email: \"$ADMIN_EMAIL\",
                password: \"$ADMIN_PASSWORD\",
                role: \"admin\"
            }) do
                {:ok, user} -> IO.puts(\"Admin user created: #{user.email}\")
                {:error, changeset} -> raise \"create_user failed: #{inspect(changeset.errors)}\"
            end
        user ->
            IO.puts(\"Admin user already exists: #{user.email}\")
    end
"

echo "E2E: initializing remote access"
su-exec mydia /app/bin/mydia rpc "
    config = Mydia.RemoteAccess.get_config()

    config =
      if is_nil(config) do
        case Mydia.RemoteAccess.initialize_keypair() do
          {:ok, c} -> c
          {:error, reason} -> raise \"initialize_keypair failed: #{inspect(reason)}\"
        end
      else
        config
      end

    unless Map.get(config, :enabled) do
      case Mydia.RemoteAccess.toggle_remote_access(true) do
        {:ok, _} -> IO.puts(\"Remote access enabled\")
        {:error, reason} -> raise \"toggle_remote_access failed: #{inspect(reason)}\"
      end
    end
"

echo "E2E: generating test video"
mkdir -p /media/movies
ffmpeg -y -f lavfi -i testsrc2=duration=5:size=1280x720:rate=24 \
       -f lavfi -i sine=frequency=440:duration=5 \
       -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
       -g 24 -keyint_min 24 \
       -c:a aac -b:a 128k \
       -movflags +faststart \
       "$VIDEO_PATH"
chown mydia:mydia "$VIDEO_PATH"

echo "E2E: seeding library entries"
su-exec mydia /app/bin/mydia rpc "
    alias Mydia.{Settings, Media, Library, Repo}
    alias Mydia.Settings.LibraryPath

    file_size = File.stat!(\"$VIDEO_PATH\").size

    lib_path =
      case Repo.get_by(LibraryPath, path: \"/media/movies\") do
        nil ->
          case Settings.create_library_path(%{path: \"/media/movies\", type: :movies}) do
            {:ok, lp} -> lp
            {:error, reason} -> raise \"create_library_path failed: #{inspect(reason)}\"
          end
        existing -> existing
      end

    with {:ok, movie} <- Media.create_media_item(%{type: \"movie\", title: \"E2E Test Movie\", year: 2025}, skip_episode_refresh: true),
         {:ok, _file} <- Library.create_media_file(%{
           media_item_id: movie.id,
           library_path_id: lib_path.id,
           relative_path: \"e2e-test-video.mp4\",
           size: file_size,
           resolution: \"720p\",
           codec: \"h264\",
           audio_codec: \"aac\",
           metadata: %{\"duration\" => 5.0}
         }) do
      IO.puts(\"Test media seeded: E2E Test Movie (#{file_size} bytes)\")
    else
      {:error, reason} -> raise \"seed media failed: #{inspect(reason)}\"
    end
"

sh "$SCRIPT_DIR/assert-seeded.sh"
echo "E2E setup complete."
