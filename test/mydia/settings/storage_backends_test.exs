defmodule Mydia.Settings.StorageBackendsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.Settings.StorageBackend

  @valid %{
    name: "media",
    endpoint: "http://127.0.0.1:9000",
    region: "us-east-1",
    bucket: "library",
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "s3cr3t",
    path_style: true
  }

  test "create, fetch by name, update, delete" do
    assert {:ok, %StorageBackend{} = b} = Settings.create_storage_backend(@valid)
    assert Settings.get_storage_backend_by_name("media").id == b.id
    assert {:ok, b} = Settings.update_storage_backend(b, %{bucket: "other"})
    assert b.bucket == "other"
    assert {:ok, _} = Settings.delete_storage_backend(b)
    assert Settings.get_storage_backend_by_name("media") == nil
  end

  test "the secret access key is a filtered parameter" do
    filtered =
      Phoenix.Logger.filter_values(%{"storage_backend" => %{"secret_access_key" => "s3cr3t"}})

    refute inspect(filtered) =~ "s3cr3t"
  end

  test "a backend still referenced by a library path cannot be deleted" do
    {:ok, b} = Settings.create_storage_backend(@valid)

    {:ok, _} =
      Settings.create_library_path(%{path: "s3://media/movies", type: :movies, monitored: true})

    assert {:error, %Ecto.Changeset{} = cs} = Settings.delete_storage_backend(b)
    assert %{base: [message]} = errors_on(cs)
    assert message =~ "library"
    assert Settings.get_storage_backend_by_name("media")
  end

  test "a backend whose name is only a prefix of another's can be deleted" do
    {:ok, b} = Settings.create_storage_backend(@valid)
    {:ok, _} = Settings.create_storage_backend(%{@valid | name: "media2"})

    {:ok, _} =
      Settings.create_library_path(%{path: "s3://media2/movies", type: :movies, monitored: true})

    assert {:ok, _} = Settings.delete_storage_backend(b)
  end

  test "name, bucket and keys are required; name is unique" do
    assert {:error, cs} = Settings.create_storage_backend(%{})
    errors = errors_on(cs)
    for f <- [:name, :bucket, :access_key_id, :secret_access_key], do: assert(errors[f])

    {:ok, _} = Settings.create_storage_backend(@valid)
    assert {:error, cs} = Settings.create_storage_backend(@valid)
    assert "has already been taken" in errors_on(cs).name
  end

  test "name must be usable as the host part of s3://<name>/" do
    assert {:error, cs} = Settings.create_storage_backend(%{@valid | name: "has/slash"})
    assert errors_on(cs).name
  end

  test "endpoint_url/1 derives the AWS endpoint from region when blank" do
    assert StorageBackend.endpoint_url(%StorageBackend{endpoint: nil, region: "eu-west-1"}) ==
             "https://s3.eu-west-1.amazonaws.com"

    assert StorageBackend.endpoint_url(%StorageBackend{endpoint: "http://h:9000/"}) ==
             "http://h:9000"
  end

  test "secret is redacted from inspect" do
    {:ok, b} = Settings.create_storage_backend(@valid)
    refute inspect(b) =~ "s3cr3t"
  end

  test "runtime (env/YAML) backends are listed and found by name" do
    original = Application.get_env(:mydia, :runtime_config)
    on_exit(fn -> Application.put_env(:mydia, :runtime_config, original) end)

    # RuntimeConfig getters require a struct, so start from the schema defaults.
    Application.put_env(:mydia, :runtime_config, %{
      Mydia.Config.Schema.defaults()
      | storage_backends: [Map.put(@valid, :name, "from-env")]
    })

    assert %StorageBackend{name: "from-env", id: "runtime::storage_backend::from-env"} =
             Settings.get_storage_backend_by_name("from-env")
  end
end
