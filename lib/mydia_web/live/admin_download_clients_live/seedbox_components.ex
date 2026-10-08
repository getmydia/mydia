defmodule MydiaWeb.AdminDownloadClientsLive.SeedboxComponents do
  @moduledoc false
  use MydiaWeb, :html

  attr :download_client_form, :any, required: true

  def remote_fetch_section(assigns) do
    ~H"""
    <details class="collapse collapse-arrow bg-base-200" id="download-client-remote-fetch">
      <summary class="collapse-title text-sm font-medium">
        Remote seedbox (pull over SFTP)
      </summary>
      <div class="collapse-content space-y-3">
        <label class="label cursor-pointer justify-start gap-3">
          <input
            type="hidden"
            name="download_client_config[connection_settings][remote_fetch][enabled]"
            value="false"
          />
          <input
            type="checkbox"
            name="download_client_config[connection_settings][remote_fetch][enabled]"
            value="true"
            checked={remote_fetch_value(@download_client_form, "enabled") in [true, "true"]}
            class="checkbox checkbox-sm"
          />
          <span class="label-text">
            Pull completed torrents from this client's host over SFTP
          </span>
        </label>

        <p class="text-xs text-base-content/60">
          Connection trust is not verified (no host-key checking) — only connect to hosts you control.
        </p>

        <.input
          name="download_client_config[connection_settings][remote_fetch][host]"
          type="text"
          label="SFTP Host"
          placeholder="seedbox.example.com"
          value={remote_fetch_value(@download_client_form, "host")}
        />

        <.input
          name="download_client_config[connection_settings][remote_fetch][port]"
          type="number"
          label="SFTP Port"
          value={remote_fetch_value(@download_client_form, "port") || 22}
        />

        <.input
          name="download_client_config[connection_settings][remote_fetch][username]"
          type="text"
          label="SFTP Username"
          value={remote_fetch_value(@download_client_form, "username")}
        />

        <.input
          name="download_client_config[connection_settings][remote_fetch][auth_method]"
          type="select"
          label="Authentication"
          options={
            Enum.map(
              Mydia.Settings.DownloadClientConfig.remote_fetch_auth_methods(),
              &{auth_method_label(&1), &1}
            )
          }
          value={remote_fetch_value(@download_client_form, "auth_method") || "password"}
        />

        <%= if remote_fetch_value(@download_client_form, "auth_method") == "ssh_key" do %>
          <.input
            name="download_client_config[connection_settings][remote_fetch][private_key]"
            type="textarea"
            label="Private Key (PEM)"
            value={remote_fetch_value(@download_client_form, "private_key")}
          />
          <.input
            name="download_client_config[connection_settings][remote_fetch][passphrase]"
            type="password"
            label="Passphrase (optional)"
            value={remote_fetch_value(@download_client_form, "passphrase")}
          />
        <% else %>
          <.input
            name="download_client_config[connection_settings][remote_fetch][password]"
            type="password"
            label="SFTP Password"
            value={remote_fetch_value(@download_client_form, "password")}
          />
        <% end %>

        <details class="collapse collapse-arrow bg-base-100">
          <summary class="collapse-title text-xs font-medium">Advanced</summary>
          <div class="collapse-content space-y-3">
            <.input
              name="download_client_config[connection_settings][remote_fetch][remote_path_prefix]"
              type="text"
              label="Remote Path Prefix Override"
              placeholder="Leave blank unless SFTP is chrooted differently from the torrent client"
              value={remote_fetch_value(@download_client_form, "remote_path_prefix")}
            />

            <.input
              name="download_client_config[connection_settings][remote_fetch][max_concurrent_transfers]"
              type="number"
              label="Max Concurrent Transfers"
              value={remote_fetch_value(@download_client_form, "max_concurrent_transfers") || 2}
            />

            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="hidden"
                name="download_client_config[connection_settings][remote_fetch][delete_after_transfer]"
                value="false"
              />
              <input
                type="checkbox"
                name="download_client_config[connection_settings][remote_fetch][delete_after_transfer]"
                value="true"
                checked={
                  remote_fetch_value(@download_client_form, "delete_after_transfer") in [
                    true,
                    "true"
                  ]
                }
                class="checkbox checkbox-sm"
              />
              <span class="label-text">Delete the remote copy after a verified transfer</span>
            </label>
          </div>
        </details>

        <div class="pt-1">
          <button
            type="button"
            class="btn btn-sm btn-outline"
            phx-click="test_seedbox_connection"
            disabled={remote_fetch_value(@download_client_form, "host") in [nil, ""]}
          >
            <.icon name="hero-signal" class="w-4 h-4" /> Test SFTP Connection
          </button>
        </div>
      </div>
    </details>
    """
  end

  # Reads a key out of the nested `connection_settings.remote_fetch` map for
  # the form's current (possibly unsaved) state, mirroring the
  # `get_in(Phoenix.HTML.Form.input_value(...), [...])` pattern used above for
  # blackhole's `watch_folder`.
  defp remote_fetch_value(form, key) do
    get_in(
      Phoenix.HTML.Form.input_value(form, :connection_settings) || %{},
      ["remote_fetch", key]
    )
  end

  defp auth_method_label("password"), do: "Password"
  defp auth_method_label("ssh_key"), do: "SSH key"
end
