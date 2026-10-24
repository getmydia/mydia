defmodule MydiaWeb.VideoPlayerComponents do
  @moduledoc """
  The in-browser video player: custom controls driven by the Alpine
  `videoPlayer()` component and the `VideoPlayer` hook.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders a video player component with playback progress tracking.

  Supports both direct play (browser-compatible files) and HLS adaptive streaming.
  Automatically saves and resumes playback position.

  ## Examples

      <.video_player content_type="movie" content_id={@media_item.id} />
      <.video_player content_type="episode" content_id={@episode.id} />
      <.video_player content_type="movie" content_id={@media_item.id} autoplay={true} />
  """
  attr :content_type, :string, required: true, doc: "Type of content: 'movie' or 'episode'"
  attr :content_id, :string, required: true, doc: "ID of the media_item or episode"
  attr :autoplay, :boolean, default: false, doc: "Whether to autoplay the video"
  attr :controls, :boolean, default: true, doc: "Whether to show video controls"
  attr :class, :string, default: "", doc: "Additional CSS classes for the container"
  attr :next_episode, :map, default: nil, doc: "Next episode info map (for TV shows)"
  attr :intro_start, :any, default: nil, doc: "Intro start timestamp in seconds"
  attr :intro_end, :any, default: nil, doc: "Intro end timestamp in seconds"
  attr :credits_start, :any, default: nil, doc: "Credits start timestamp in seconds"

  attr :known_duration, :any,
    default: nil,
    doc: "Known duration in seconds (from FFprobe metadata)"

  def video_player(assigns) do
    ~H"""
    <div
      x-data="videoPlayer()"
      phx-hook="VideoPlayer"
      id={"video-player-#{@content_type}-#{@content_id}"}
      data-content-type={@content_type}
      data-content-id={@content_id}
      data-next-episode={if @next_episode, do: Jason.encode!(@next_episode), else: nil}
      data-intro-start={@intro_start}
      data-intro-end={@intro_end}
      data-credits-start={@credits_start}
      data-known-duration={@known_duration}
      class={["relative bg-black rounded-lg overflow-hidden flex items-center justify-center", @class]}
      x-bind:class="{ 'cursor-none': !controlsVisible }"
    >
      <video
        x-ref="video"
        id={"video-#{@content_type}-#{@content_id}"}
        class="w-full h-auto max-h-[80vh] bg-black object-contain"
        controls={false}
        autoplay={@autoplay}
        muted={@autoplay}
        preload="metadata"
        playsinline
        @play="onPlay"
        @pause="onPause"
        @timeupdate="onTimeUpdate"
        @loadedmetadata="onLoadedMetadata"
        @durationchange="onDurationChange"
        @volumechange="onVolumeChange"
        @waiting="onWaiting"
        @playing="onPlaying"
        @ratechange="onRateChange"
      >
        {gettext("Your browser does not support video playback.")}
      </video>

      <%!-- Custom video controls --%>
      <div
        class="controls absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/80 to-transparent px-4 pb-4 pt-12 transition-opacity duration-300"
        x-show="controlsVisible"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0"
        x-transition:enter-end="opacity-100"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-bind:class="{ 'pointer-events-none opacity-0': !controlsVisible }"
      >
        <%!-- Progress bar --%>
        <div class="progress-container mb-4 group cursor-pointer">
          <input
            type="range"
            min="0"
            max="100"
            x-bind:value="progressPercent"
            @input="setProgress($event.target.value)"
            step="0.1"
            class="progress-bar range range-xs range-primary w-full opacity-80 hover:opacity-100 transition-opacity"
          />
        </div>

        <%!-- Control buttons row --%>
        <div class="flex items-center gap-1">
          <%!-- Play/Pause button --%>
          <button
            type="button"
            @click="togglePlay"
            class="p-2 text-white/90 hover:text-white transition-colors"
            aria-label={gettext("Play/Pause")}
          >
            <.icon x-show="!playing" name="hero-play-solid" class="w-7 h-7" />
            <.icon x-show="playing" x-cloak name="hero-pause-solid" class="w-7 h-7" />
          </button>

          <%!-- Skip backward 10s --%>
          <button
            type="button"
            @click="skipBackward(10)"
            class="p-2 text-white/80 hover:text-white transition-colors"
            aria-label={gettext("Skip backward 10 seconds")}
          >
            <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor">
              <path d="M12.5 3C17.15 3 21.08 6.03 22.47 10.22L20.1 11C19.05 7.81 16.04 5.5 12.5 5.5C10.54 5.5 8.77 6.22 7.38 7.38L10 10H3V3L5.6 5.6C7.45 4 9.85 3 12.5 3Z" />
              <text
                x="12"
                y="17"
                font-size="7"
                font-weight="600"
                text-anchor="middle"
                fill="currentColor"
              >
                10
              </text>
            </svg>
          </button>

          <%!-- Skip forward 10s --%>
          <button
            type="button"
            @click="skipForward(10)"
            class="p-2 text-white/80 hover:text-white transition-colors"
            aria-label={gettext("Skip forward 10 seconds")}
          >
            <svg class="w-6 h-6" viewBox="0 0 24 24" fill="currentColor">
              <path d="M11.5 3C6.85 3 2.92 6.03 1.53 10.22L3.9 11C4.95 7.81 7.96 5.5 11.5 5.5C13.46 5.5 15.23 6.22 16.62 7.38L14 10H21V3L18.4 5.6C16.55 4 14.15 3 11.5 3Z" />
              <text
                x="12"
                y="17"
                font-size="7"
                font-weight="600"
                text-anchor="middle"
                fill="currentColor"
              >
                10
              </text>
            </svg>
          </button>

          <%!-- Volume controls - hidden on mobile --%>
          <div class="hidden md:flex items-center gap-1 ml-2">
            <button
              type="button"
              @click="toggleMute"
              class="p-2 text-white/80 hover:text-white transition-colors"
              aria-label={gettext("Mute/Unmute")}
            >
              <.icon x-show="!muted && volume > 50" name="hero-speaker-wave" class="w-5 h-5" />
              <.icon
                x-show="!muted && volume > 0 && volume <= 50"
                x-cloak
                name="hero-speaker-wave"
                class="w-5 h-5 opacity-70"
              />
              <.icon
                x-show="muted || volume === 0"
                x-cloak
                name="hero-speaker-x-mark"
                class="w-5 h-5"
              />
            </button>
            <input
              type="range"
              min="0"
              max="100"
              x-bind:value="volume"
              @input="setVolume($event.target.value)"
              class="volume-slider range range-xs range-primary w-20 opacity-70 hover:opacity-100 transition-opacity"
            />
          </div>

          <%!-- Time display --%>
          <div class="text-white/80 text-sm font-medium ml-3 hidden sm:block tabular-nums">
            <span x-text="formattedCurrentTime">0:00</span>
            <span class="mx-1 text-white/50">/</span>
            <span x-text="formattedDuration" class="text-white/60">0:00</span>
          </div>

          <%!-- Streaming mode badge --%>
          <div
            x-show="streamingMode"
            x-cloak
            class="hidden sm:flex items-center ml-3"
          >
            <span
              x-text="streamingModeDisplay"
              x-bind:class="{
                'bg-green-500/20 text-green-400 border-green-500/30': streamingMode !== 'transcode',
                'bg-orange-500/20 text-orange-400 border-orange-500/30': streamingMode === 'transcode'
              }"
              class="px-2 py-0.5 text-xs font-medium rounded border"
            ></span>
          </div>

          <div class="flex-1"></div>

          <%!-- Settings button --%>
          <div class="settings-container relative">
            <button
              type="button"
              @click="toggleSettings"
              class="p-2 text-white/80 hover:text-white transition-colors"
              aria-label={gettext("Settings")}
            >
              <.icon name="hero-cog-6-tooth" class="w-5 h-5" />
            </button>

            <%!-- Settings menu --%>
            <div
              x-show="settingsOpen"
              x-transition:enter="transition ease-out duration-150"
              x-transition:enter-start="opacity-0 scale-95"
              x-transition:enter-end="opacity-100 scale-100"
              x-transition:leave="transition ease-in duration-100"
              x-transition:leave-start="opacity-100 scale-100"
              x-transition:leave-end="opacity-0 scale-95"
              x-cloak
              @click.outside="closeSettings"
              class="absolute bottom-full right-0 mb-2 bg-neutral/95 backdrop-blur-sm rounded-lg shadow-xl min-w-[180px] overflow-hidden"
            >
              <%!-- Playback Speed submenu --%>
              <div class="speed-menu-container">
                <button
                  type="button"
                  @click="toggleSpeedMenu"
                  class="w-full px-4 py-2.5 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors"
                >
                  <span class="text-sm">{gettext("Speed")}</span>
                  <div class="flex items-center gap-2">
                    <span x-text="speedDisplay" class="text-sm text-white/60">
                      {gettext("Normal")}
                    </span>
                    <.icon name="hero-chevron-right" class="w-4 h-4 text-white/40" />
                  </div>
                </button>

                <%!-- Speed options submenu --%>
                <div
                  x-show="speedMenuOpen"
                  x-transition
                  x-cloak
                  class="absolute bottom-0 right-full mr-1 bg-neutral/95 backdrop-blur-sm rounded-lg shadow-xl min-w-[120px] overflow-hidden"
                >
                  <button
                    :for={speed <- [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]}
                    type="button"
                    @click={"setSpeed(#{speed})"}
                    class="w-full px-4 py-2 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors text-sm"
                  >
                    <span>{if speed == 1.0, do: gettext("Normal"), else: "#{speed}x"}</span>
                    <.icon
                      x-show={"Math.abs(playbackRate - #{speed}) < 0.01"}
                      name="hero-check"
                      class="w-4 h-4 text-primary"
                    />
                  </button>
                </div>
              </div>

              <%!-- Quality submenu (shown when HLS is active) --%>
              <div
                x-show="hlsLevels.length > 0"
                class="quality-menu-container border-t border-white/10"
              >
                <button
                  type="button"
                  @click="toggleQualityMenu"
                  class="w-full px-4 py-2.5 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors"
                >
                  <span class="text-sm">{gettext("Quality")}</span>
                  <div class="flex items-center gap-2">
                    <span x-text="qualityDisplay" class="text-sm text-white/60">
                      {gettext("Auto")}
                    </span>
                    <.icon name="hero-chevron-right" class="w-4 h-4 text-white/40" />
                  </div>
                </button>

                <%!-- Quality options submenu --%>
                <div
                  x-show="qualityMenuOpen"
                  x-transition
                  x-cloak
                  class="absolute bottom-0 right-full mr-1 bg-neutral/95 backdrop-blur-sm rounded-lg shadow-xl min-w-[120px] overflow-hidden"
                >
                  <button
                    type="button"
                    @click="setQuality(-1)"
                    class="w-full px-4 py-2 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors text-sm"
                  >
                    <span>{gettext("Auto")}</span>
                    <.icon
                      x-show="currentHlsLevel === -1"
                      name="hero-check"
                      class="w-4 h-4 text-primary"
                    />
                  </button>
                  <template x-for="(level, index) in hlsLevels">
                    <button
                      type="button"
                      @click="setQuality(index)"
                      class="w-full px-4 py-2 text-left hover:bg-white/10 flex items-center justify-between text-white transition-colors text-sm"
                    >
                      <span x-text="level.height + 'p'"></span>
                      <.icon
                        x-show="currentHlsLevel === index"
                        name="hero-check"
                        class="w-4 h-4 text-primary"
                      />
                    </button>
                  </template>
                </div>
              </div>
            </div>
          </div>

          <%!-- Fullscreen button --%>
          <button
            type="button"
            @click="toggleFullscreen"
            class="p-2 text-white/80 hover:text-white transition-colors"
            aria-label={gettext("Toggle Fullscreen")}
          >
            <.icon x-show="!isFullscreen" name="hero-arrows-pointing-out" class="w-5 h-5" />
            <.icon x-show="isFullscreen" x-cloak name="hero-arrows-pointing-in" class="w-5 h-5" />
          </button>
        </div>
      </div>

      <%!-- Loading indicator --%>
      <div
        x-show="loading"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0"
        x-transition:enter-end="opacity-100"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute inset-0 flex items-center justify-center bg-black/80 pointer-events-none z-10"
      >
        <div class="flex flex-col items-center gap-3">
          <span class="loading loading-ring loading-lg text-white"></span>
          <p class="text-white/80 text-sm" x-text="loadingMessage">
            {gettext("Loading...")}
          </p>
        </div>
      </div>

      <%!-- Error message --%>
      <div
        x-show="error"
        x-transition
        x-cloak
        class="absolute inset-0 flex items-center justify-center bg-black/90 z-10"
      >
        <div class="flex flex-col items-center gap-4 text-center px-6">
          <.icon name="hero-exclamation-triangle" class="w-12 h-12 text-error/80" />
          <p x-text="error" class="text-white/90 text-sm max-w-xs">
            {gettext("Error loading video")}
          </p>
          <button
            type="button"
            class="px-4 py-2 text-sm text-white/90 hover:text-white bg-white/10 hover:bg-white/20 rounded-lg transition-colors"
            onclick="window.location.reload()"
          >
            {gettext("Try Again")}
          </button>
        </div>
      </div>

      <%!-- Skip Intro button --%>
      <div
        x-show="skipIntroVisible"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0 translate-x-4"
        x-transition:enter-end="opacity-100 translate-x-0"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute bottom-24 right-4 z-20"
      >
        <button
          type="button"
          @click="skipIntro"
          class="px-4 py-2 text-sm font-medium text-white bg-white/20 hover:bg-white/30 backdrop-blur-sm rounded-lg border border-white/20 transition-all"
        >
          {gettext("Skip Intro")}
        </button>
      </div>

      <%!-- Skip Credits button --%>
      <div
        x-show="skipCreditsVisible"
        x-transition:enter="transition ease-out duration-200"
        x-transition:enter-start="opacity-0 translate-x-4"
        x-transition:enter-end="opacity-100 translate-x-0"
        x-transition:leave="transition ease-in duration-150"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute bottom-24 right-4 z-20"
      >
        <button
          type="button"
          @click="skipCredits"
          class="px-4 py-2 text-sm font-medium text-white bg-white/20 hover:bg-white/30 backdrop-blur-sm rounded-lg border border-white/20 transition-all"
        >
          {gettext("Skip Credits")}
        </button>
      </div>

      <%!-- Next Episode card --%>
      <div
        x-show="nextEpisodeVisible"
        x-transition:enter="transition ease-out duration-300"
        x-transition:enter-start="opacity-0 translate-y-4"
        x-transition:enter-end="opacity-100 translate-y-0"
        x-transition:leave="transition ease-in duration-200"
        x-transition:leave-start="opacity-100"
        x-transition:leave-end="opacity-0"
        x-cloak
        class="absolute bottom-24 right-4 z-20"
      >
        <div class="bg-neutral/95 backdrop-blur-sm rounded-box overflow-hidden max-w-xs shadow-2xl">
          <%!-- Next episode info --%>
          <div class="next-episode-info p-4 flex gap-3">
            <div class="next-episode-poster flex-shrink-0 w-20 h-28 bg-white/10 rounded-lg overflow-hidden">
              <%!-- Poster will be set via JavaScript --%>
            </div>
            <div class="flex-1 min-w-0">
              <p class="text-xs text-white/50 font-medium uppercase tracking-wider mb-1">
                {gettext("Up Next")}
              </p>
              <h3 class="next-episode-title text-sm font-medium text-white mb-1 line-clamp-2">
                <%!-- Title will be set via JavaScript --%>
              </h3>
              <p class="next-episode-number text-xs text-white/60">
                <%!-- Episode number will be set via JavaScript --%>
              </p>
            </div>
          </div>

          <%!-- Action buttons --%>
          <div class="px-4 pb-4 flex gap-2">
            <button
              type="button"
              @click="playNextEpisode"
              class="next-episode-play-btn flex-1 px-4 py-2 text-sm font-medium text-white bg-primary hover:bg-primary/90 rounded-lg transition-colors"
            >
              {gettext("Play Now")}
            </button>
            <button
              type="button"
              @click="cancelNextEpisode"
              class="next-episode-cancel-btn px-3 py-2 text-sm text-white/70 hover:text-white hover:bg-white/10 rounded-lg transition-colors"
            >
              {gettext("Cancel")}
            </button>
          </div>

          <%!-- Auto-play countdown --%>
          <div x-show="countdownVisible" x-transition x-cloak>
            <div class="px-4 pb-3">
              <div class="flex items-center justify-between text-xs text-white/60 mb-2">
                <span>{gettext("Playing in")}</span>
                <span x-text="countdownSeconds + 's'" class="countdown-time text-white/80">
                  {gettext("%{seconds}s", seconds: 15)}
                </span>
              </div>
              <div class="countdown-progress-bar w-full h-0.5 bg-white/20 rounded-full overflow-hidden">
                <div
                  x-bind:style="`width: ${countdownProgress}%`"
                  class="countdown-progress h-full bg-primary transition-all duration-100 ease-linear"
                >
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
