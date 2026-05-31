import { useState, useCallback, useRef } from "react";
import { useParams, Link } from "react-router-dom";
import { useQuery, useMutation } from "urql";
import { PlaybackMovieDocument, PlaybackEpisodeDocument, StartStreamingSessionDocument } from "../graphql/generated/graphql";
import type { PlaybackMovieQuery, StreamingStrategy } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Button } from "../components/button";

function formatDuration(seconds: number | null | undefined): string {
  if (!seconds) return "";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export function PlaybackPage() {
  const { type, id } = useParams<{ type: string; id: string }>();
  const [selectedFileId, setSelectedFileId] = useState<string | null>(null);
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [playerError, setPlayerError] = useState<string | null>(null);
  const videoRef = useRef<HTMLVideoElement>(null);

  const isMovie = type === "movie";
  const isEpisode = type === "episode";

  const [movieResult] = useQuery({
    query: PlaybackMovieDocument,
    variables: { id: id ?? "" },
    pause: !id || !isMovie,
  });

  const [episodeResult] = useQuery({
    query: PlaybackEpisodeDocument,
    variables: { id: id ?? "" },
    pause: !id || !isEpisode,
  });

  const [, startSession] = useMutation(StartStreamingSessionDocument);

  type FileInfo = PlaybackMovieQuery["movie"]["files"][number];
  type ProgressInfo = NonNullable<PlaybackMovieQuery["movie"]["progress"]>;

  const movie = movieResult.data?.movie;
  const episode = episodeResult.data?.episode;

  const fetching = isMovie ? movieResult.fetching : episodeResult.fetching;
  const error = isMovie ? movieResult.error : episodeResult.error;

  const files: FileInfo[] = (movie?.files ?? episode?.files ?? []) as FileInfo[];
  const title = (movie?.title ?? episode?.title) ?? "";
  const year = isMovie ? movie?.year : undefined;
  const runtime = isMovie ? movie?.runtime : undefined;
  const overview = (movie?.overview ?? episode?.overview) ?? undefined;
  const artwork = movie?.artwork ?? undefined;
  const progress = (movie?.progress ?? episode?.progress ?? undefined) as ProgressInfo | undefined;
  const seasonNumber = episode?.seasonNumber;
  const episodeNumber = episode?.episodeNumber;
  const show = episode?.show ?? undefined;

  const handlePlay = useCallback(async (fileId: string, strategy: StreamingStrategy = "HLS_COPY") => {
    setPlayerError(null);
    setSelectedFileId(fileId);
    try {
      const result = await startSession({ fileId, strategy });
      if (result.data?.startStreamingSession?.sessionId) {
        setSessionId(result.data.startStreamingSession.sessionId);
      } else {
        setPlayerError("Failed to start streaming session.");
      }
    } catch {
      setPlayerError("Failed to start streaming session.");
    }
  }, [startSession]);

  const handleResume = useCallback(() => {
    if (progress && progress.percentage != null && progress.percentage < 100) {
      const vid = videoRef.current;
      if (vid && vid.duration) {
        vid.currentTime = (progress.percentage / 100) * vid.duration;
      }
    }
  }, [progress]);

  const hlsUrl = sessionId ? `/api/v1/hls/${sessionId}/master.m3u8` : null;
  const backUrl = isEpisode && show ? `/media/${show.id}` : `/media/${id}`;

  if (fetching) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  if (error || (!movie && !episode)) {
    return (
      <div>
        <PageHeader title="Playback" />
        <div className="alert alert-error">
          Failed to load content. {type && id ? `Could not find ${type} with id ${id}.` : ""}
        </div>
      </div>
    );
  }

  const subtitle = isEpisode
    ? `${show?.title} — S${seasonNumber}E${episodeNumber}`
    : year ? `${year} — ${formatDuration(runtime)}` : undefined;

  return (
    <div>
      <PageHeader
        title={isEpisode ? (title || `Episode ${episodeNumber}`) : title}
        subtitle={subtitle}
        actions={
          <Link to={backUrl} className="btn btn-ghost btn-sm">
            <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor" className="w-5 h-5">
              <path strokeLinecap="round" strokeLinejoin="round" d="M9 15L3 9m0 0l6-6M3 9h12a6 6 0 010 12h-3" />
            </svg>
            Back
          </Link>
        }
      />

      {/* Player */}
      <div className="mb-6">
        {!sessionId ? (
          <div className="aspect-video bg-base-300 rounded-xl flex items-center justify-center">
            {files.length === 0 ? (
              <div className="text-center p-8">
                <svg xmlns="http://www.w3.org/2000/svg" className="w-16 h-16 mx-auto mb-4 text-base-content/30" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1} d="M15.75 10.5l4.72-4.72a.75.75 0 011.28.53v11.38a.75.75 0 01-1.28.53l-4.72-4.72M4.5 18.75h9a2.25 2.25 0 002.25-2.25v-9a2.25 2.25 0 00-2.25-2.25h-9A2.25 2.25 0 002.25 7.5v9a2.25 2.25 0 002.25 2.25z" />
                </svg>
                <p className="text-base-content/60">No video files available for this content.</p>
              </div>
            ) : (
              <div className="text-center p-8">
                <p className="text-base-content/60 mb-4">Select a file to start playback</p>
                <div className="flex flex-wrap gap-2 justify-center">
                  {files.map((file) => (
                    <Button
                      key={file.id}
                      variant="primary"
                      size="sm"
                      onClick={() => handlePlay(file.id)}
                      loading={!!selectedFileId && selectedFileId === file.id}
                    >
                      Play {file.resolution ?? "File"}
                    </Button>
                  ))}
                </div>
              </div>
            )}
          </div>
        ) : (
          <div className="aspect-video bg-black rounded-xl overflow-hidden relative">
            {playerError && (
              <div className="absolute top-2 right-2 z-10 alert alert-error py-1 px-3 text-sm">
                {playerError}
              </div>
            )}
            <video
              ref={videoRef}
              className="w-full h-full"
              controls
              autoPlay
              onLoadedMetadata={handleResume}
              onError={() => setPlayerError("Playback error. The file may not be ready.")}
            >
              <source src={hlsUrl!} type="application/x-mpegURL" />
            </video>
          </div>
        )}
      </div>

      {/* Content info */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-2 space-y-4">
          {overview && (
            <Card title="Overview">
              <p className="text-sm text-base-content/70">{overview}</p>
            </Card>
          )}

          {isEpisode && show && (
            <Card title="Show Info">
              <div className="flex items-center gap-3">
                {show.artwork?.posterUrl && (
                  <img src={show.artwork.posterUrl} alt={show.title} className="w-12 h-18 rounded object-cover" />
                )}
                <div>
                  <Link to={`/media/${show.id}`} className="font-semibold text-sm hover:text-primary">
                    {show.title}
                  </Link>
                  <p className="text-xs text-base-content/60">
                    Season {seasonNumber}, Episode {episodeNumber}
                  </p>
                </div>
              </div>
            </Card>
          )}
        </div>

        {/* Sidebar */}
        <div className="space-y-4">
          {artwork?.posterUrl && (
            <div className="rounded-xl overflow-hidden shadow-lg">
              <img src={artwork.posterUrl} alt={title} className="w-full aspect-[2/3] object-cover" />
            </div>
          )}

          {/* File details */}
          {files.length > 0 && (
            <Card title="Files">
              <div className="space-y-2">
                {files.map((file) => (
                  <div key={file.id} className="text-sm">
                    <div className="flex items-center justify-between">
                      <span className="font-medium">{file.resolution ?? "Unknown"}</span>
                      <span className="text-base-content/60">
                        {file.size ? `${(file.size / 1_000_000_000).toFixed(1)} GB` : ""}
                      </span>
                    </div>
                    <div className="text-xs text-base-content/50">
                      {[file.codec, file.audioCodec, file.hdrFormat].filter(Boolean).join(" / ")}
                    </div>
                    {file.subtitles.length > 0 && (
                      <div className="flex flex-wrap gap-1 mt-1">
                        {file.subtitles.map((sub) => (
                          <span key={sub.trackId} className="badge badge-xs badge-ghost">
                            {sub.language}{sub.embedded ? "" : " (ext)"}
                          </span>
                        ))}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </Card>
          )}

          {/* Progress */}
          {progress && (
            <Card title="Progress">
              <div className="space-y-2">
                <div className="w-full bg-base-300 rounded-full h-2">
                  <div
                    className="h-full bg-primary rounded-full"
                    style={{ width: `${Math.min(progress.percentage ?? 0, 100)}%` }}
                  />
                </div>
                <div className="flex items-center justify-between text-sm">
                  <span>{Math.round(progress.percentage ?? 0)}%</span>
                  {progress.watched && <span className="badge badge-success badge-sm">Watched</span>}
                </div>
              </div>
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}
