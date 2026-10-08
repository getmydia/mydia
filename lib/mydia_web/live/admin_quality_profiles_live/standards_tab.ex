defmodule MydiaWeb.AdminQualityProfilesLive.StandardsTab do
  @moduledoc false
  use MydiaWeb, :html

  @doc """
  Renders the Quality Standards tab content for the Quality Profile modal.
  """
  attr :form, :any, required: true

  def quality_profile_standards_tab(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5" />
        <span class="text-sm">
          Configure quality standards including codecs, bitrates, resolutions, and file sizes. Leave fields empty to allow any value.
        </span>
      </div>

      <%!-- Video Codecs --%>
      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Video Codecs</span>
          <span class="label-text-alt text-xs">In priority order</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-5 gap-2">
          <%= for codec <- ["h265", "h264", "av1", "hevc", "x264", "x265", "vc1", "mpeg2", "xvid", "divx"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_video_codecs][]"
                value={codec}
                checked={
                  codec in (get_in(
                              Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                              [:preferred_video_codecs]
                            ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{codec}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Audio Settings --%>
      <div class="divider">Audio Settings</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Audio Codecs</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-5 gap-2">
          <%= for codec <- ["aac", "ac3", "eac3", "dts", "dts-hd", "truehd", "atmos", "flac", "mp3", "opus"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_audio_codecs][]"
                value={codec}
                checked={
                  codec in (get_in(
                              Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                              [:preferred_audio_codecs]
                            ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{codec}</span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Audio Channels</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-4 gap-2">
          <%= for channels <- ["1.0", "2.0", "2.1", "5.1", "6.1", "7.1", "7.1.2", "7.1.4"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_audio_channels][]"
                value={channels}
                checked={
                  channels in (get_in(
                                 Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                                 [:preferred_audio_channels]
                               ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{channels}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Resolution Settings --%>
      <div class="divider">Resolution Settings</div>

      <p id="resolution-limits-hint" class="text-xs text-base-content/70">
        Automatic grabs and upgrades never go outside these. Manual search still lists
        everything and marks what is outside.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label">
            <span class="label-text">Minimum Resolution</span>
          </label>
          <select
            name="quality_profile[quality_standards][min_resolution]"
            class="select select-bordered w-full"
          >
            <option value="">No minimum</option>
            <%= for res <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
              <option
                value={res}
                selected={
                  res ==
                    get_in(
                      Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                      [:min_resolution]
                    )
                }
              >
                {res}
              </option>
            <% end %>
          </select>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text">Maximum Resolution</span>
          </label>
          <select
            name="quality_profile[quality_standards][max_resolution]"
            class="select select-bordered w-full"
          >
            <option value="">No maximum</option>
            <%= for res <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
              <option
                value={res}
                selected={
                  res ==
                    get_in(
                      Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                      [:max_resolution]
                    )
                }
              >
                {res}
              </option>
            <% end %>
          </select>
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Resolutions</span>
        </label>
        <div class="grid grid-cols-3 md:grid-cols-4 gap-2">
          <%= for res <- ["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_resolutions][]"
                value={res}
                checked={
                  res in (get_in(
                            Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                            [:preferred_resolutions]
                          ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{res}</span>
            </label>
          <% end %>
        </div>
      </div>

      <%!-- Source Preferences --%>
      <div class="divider">Source Preferences</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred Sources</span>
          <span class="label-text-alt text-xs">In priority order</span>
        </label>
        <div class="grid grid-cols-2 md:grid-cols-3 gap-2">
          <%= for source <- ["BluRay", "BDRip", "REMUX", "WEB-DL", "WEBRip", "HDTV", "SDTV", "DVD", "DVDRip"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][preferred_sources][]"
                value={source}
                checked={
                  source in (get_in(
                               Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                               [:preferred_sources]
                             ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{source}</span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Minimum seeder ratio (torrents)</span>
        </label>
        <input
          type="number"
          name="quality_profile[quality_standards][min_ratio]"
          placeholder="e.g. 0.2"
          step="0.05"
          min="0"
          value={
            get_in(
              Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
              [:min_ratio]
            )
          }
          class="input input-bordered w-full"
        />
        <label class="label">
          <span class="label-text-alt">
            A preference: torrents below this seeder/leecher ratio rank lower but can still be grabbed. Leave blank to disable.
          </span>
        </label>
      </div>

      <%!-- File Size Constraints --%>
      <div class="divider">File Size Limits (MB)</div>
      <p id="size-limits-hint" class="text-xs text-base-content/70">
        Automatic grabs and upgrades never go outside these. A season pack is judged per
        episode. Manual search still lists everything and marks what is outside.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Movie File Sizes</span>
          </label>
          <div class="space-y-2">
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][movie_min_size_mb]"
                placeholder="Min size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:movie_min_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Minimum</span>
              </label>
            </div>
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][movie_max_size_mb]"
                placeholder="Max size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:movie_max_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Maximum</span>
              </label>
            </div>
          </div>
        </div>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold">Episode File Sizes</span>
          </label>
          <div class="space-y-2">
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][episode_min_size_mb]"
                placeholder="Min size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:episode_min_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Minimum</span>
              </label>
            </div>
            <div>
              <input
                type="number"
                name="quality_profile[quality_standards][episode_max_size_mb]"
                placeholder="Max size (MB)"
                step="1"
                min="0"
                value={
                  get_in(
                    Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                    [:episode_max_size_mb]
                  )
                }
                class="input input-bordered w-full"
              />
              <label class="label">
                <span class="label-text-alt">Maximum</span>
              </label>
            </div>
          </div>
        </div>
      </div>

      <%!-- HDR/Dolby Vision --%>
      <div class="divider">HDR/Dolby Vision</div>

      <div class="form-control">
        <label class="label">
          <span class="label-text font-semibold">Preferred HDR Formats</span>
        </label>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-2">
          <%= for format <- ["hdr10", "hdr10+", "dolby_vision", "hlg"] do %>
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="quality_profile[quality_standards][hdr_formats][]"
                value={format}
                checked={
                  format in (get_in(
                               Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                               [:hdr_formats]
                             ) || [])
                }
                class="checkbox checkbox-sm checkbox-primary"
              />
              <span class="label-text text-sm">{String.upcase(format)}</span>
            </label>
          <% end %>
        </div>
      </div>

      <div class="form-control">
        <label class="label cursor-pointer justify-start gap-3">
          <input type="hidden" name="quality_profile[quality_standards][require_hdr]" value="false" />
          <input
            type="checkbox"
            name="quality_profile[quality_standards][require_hdr]"
            value="true"
            checked={
              get_in(
                Ecto.Changeset.get_field(@form.source, :quality_standards, %{}),
                [:require_hdr]
              ) == true
            }
            class="checkbox checkbox-primary"
          />
          <div>
            <span class="label-text font-semibold">Require HDR</span>
            <p class="text-xs text-base-content/70">
              Automatic grabs and upgrades skip releases without HDR in the name
            </p>
          </div>
        </label>
      </div>
    </div>
    """
  end
end
