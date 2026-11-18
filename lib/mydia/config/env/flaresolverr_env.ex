defmodule Mydia.Config.Env.FlareSolverrEnv do
  @moduledoc """
  Reads the `flaresolverr` section of `Mydia.Config.Schema` from the
  environment (`FLARESOLVERR_*`). A missing or empty variable leaves the key out.
  """

  alias Mydia.Config.Loader

  @spec load((String.t() -> String.t() | nil)) :: map()
  def load(getenv \\ &System.get_env/1) do
    %{}
    |> Loader.put_if_present(:enabled, getenv.("FLARESOLVERR_ENABLED"), &Loader.parse_boolean/1)
    |> Loader.put_if_present(:url, getenv.("FLARESOLVERR_URL"))
    |> Loader.put_if_present(:timeout, getenv.("FLARESOLVERR_TIMEOUT"), &Loader.parse_integer/1)
    |> Loader.put_if_present(
      :max_timeout,
      getenv.("FLARESOLVERR_MAX_TIMEOUT"),
      &Loader.parse_integer/1
    )
    |> Loader.put_if_present(
      :max_concurrent_requests,
      getenv.("FLARESOLVERR_MAX_CONCURRENT_REQUESTS"),
      &Loader.parse_integer/1
    )
  end
end
