defmodule MetadataRelayWeb.AuthHTML do
  @moduledoc """
  Markup for the maintainer sign-in page.
  """

  use Phoenix.Component

  attr(:flash, :map, default: %{})
  attr(:error, :string, default: nil)

  def login(assigns) do
    ~H"""
    <MetadataRelayWeb.Layouts.app flash={@flash}>
      <section id="sign-in" class="mx-auto w-full max-w-md py-16">
        <div class="card border border-base-300 bg-base-100 shadow-xl">
          <div class="card-body items-center gap-6 text-center">
            <div class="badge badge-primary badge-lg">Maintainer dashboard</div>

            <div class="space-y-2">
              <h1 class="text-3xl font-semibold tracking-tight">Metadata Relay</h1>
              <p class="text-base-content/70">
                Sign in with GitHub to review feedback and error reports.
              </p>
            </div>

            <div :if={@error} id="sign-in-error" class="alert alert-error">
              <span>{@error}</span>
            </div>

            <a id="sign-in-github" href="/auth/github" class="btn btn-primary btn-wide">
              Sign in with GitHub
            </a>
          </div>
        </div>
      </section>
    </MetadataRelayWeb.Layouts.app>
    """
  end
end
