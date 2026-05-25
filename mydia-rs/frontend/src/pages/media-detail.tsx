import { useParams, useNavigate } from "react-router-dom";
import { useQuery, useMutation } from "urql";
import {
  MediaDetailDocument,
  ToggleMediaMonitoredDocument,
  DeleteMediaDocument,
} from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Button } from "../components/button";
import { Modal, type ModalHandle } from "../components/modal";
import { StatusPill } from "../components/status-pill";
import { useRef, useState, useCallback } from "react";

export function MediaDetailPage() {
  const { id } = useParams<{ id: string }>();
  const navigate = useNavigate();
  const deleteModalRef = useRef<ModalHandle>(null);

  const [{ data, fetching, error }] = useQuery({
    query: MediaDetailDocument,
    variables: { id: id ?? "" },
    pause: !id,
  });

  const [, toggleMonitored] = useMutation(ToggleMediaMonitoredDocument);
  const [{ fetching: deleting }, deleteMedia] = useMutation(DeleteMediaDocument);

  const [deleteError, setDeleteError] = useState<string | null>(null);

  const node = data?.node as Record<string, unknown> | null | undefined;

  const extractBase = () => {
    if (!node || typeof node !== "object") return null;
    const n = node as Record<string, unknown>;
    return {
      id: String(n.id ?? ""),
      title: String(n.title ?? "Unknown"),
      year: typeof n.year === "number" ? n.year : null,
      overview: typeof n.overview === "string" ? n.overview : null,
      monitored: Boolean(n.monitored),
      artwork: n.artwork as { posterUrl?: string | null; backdropUrl?: string | null } | null,
    };
  };

  const media = extractBase();
  const files = (node && Array.isArray((node as Record<string, unknown>).files)
    ? (node as Record<string, unknown>).files
    : []) as Array<{ id: string; streamUrl: string; size: number | null }>;
  const seasons = (node && Array.isArray((node as Record<string, unknown>).seasons)
    ? (node as Record<string, unknown>).seasons
    : []) as Array<{ seasonNumber: number; episodeCount: number }>;

  const isMovie = files.length > 0 || (!files.length && !seasons.length && media?.id);
  const isTvShow = seasons.length > 0;
  const title = media?.title ?? "Unknown";
  const year = media?.year;
  const overview = media?.overview;
  const monitored = media?.monitored ?? false;
  const posterUrl = media?.artwork?.posterUrl ?? null;

  const handleToggleMonitored = useCallback(async () => {
    if (!id) return;
    await toggleMonitored({ id });
  }, [id, toggleMonitored]);

  const handleDelete = useCallback(async () => {
    if (!id) return;
    setDeleteError(null);
    const res = await deleteMedia({ id });
    if (res.error) {
      setDeleteError(res.error.message);
    } else {
      navigate("/discover");
    }
  }, [id, deleteMedia, navigate]);

  if (fetching) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  if (error) {
    return (
      <div>
        <div className="alert alert-error">Failed to load media details.</div>
      </div>
    );
  }

  if (!media) {
    return (
      <div>
        <div className="alert alert-warning">Media not found.</div>
      </div>
    );
  }

  return (
    <div>
      <PageHeader title={title} subtitle={year ? String(year) : undefined} />

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <div className="lg:col-span-1">
          <Card>
            {posterUrl ? (
              <figure className="rounded-lg overflow-hidden">
                <img
                  src={posterUrl}
                  alt={title}
                  className="w-full object-cover"
                />
              </figure>
            ) : (
              <div className="aspect-[2/3] bg-base-200 rounded-lg flex items-center justify-center">
                <span className="text-base-content/30 text-4xl">No Poster</span>
              </div>
            )}
          </Card>
        </div>

        <div className="lg:col-span-2 space-y-4">
          <Card title="Details">
            <div className="space-y-3">
              {overview && (
                <p className="text-sm text-base-content/80">{overview}</p>
              )}
              <div className="flex flex-wrap gap-2">
                <StatusPill
                  status={monitored ? "active" : "inactive"}
                  label={monitored ? "Monitored" : "Not Monitored"}
                />
                {isMovie && <StatusPill status="active" label="Movie" />}
                {isTvShow && <StatusPill status="active" label="TV Show" />}
              </div>
            </div>
            <div className="card-actions mt-4 flex gap-2">
              <Button onClick={handleToggleMonitored} variant="outline">
                {monitored ? "Stop Monitoring" : "Start Monitoring"}
              </Button>
              <Button
                variant="error"
                onClick={() => deleteModalRef.current?.show()}
              >
                Delete
              </Button>
            </div>
          </Card>

          {isTvShow && (
            <Card title="Seasons">
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                {seasons.map((season) => (
                  <div
                    key={season.seasonNumber}
                    className="btn btn-outline btn-sm"
                  >
                    Season {season.seasonNumber} ({season.episodeCount} eps)
                  </div>
                ))}
              </div>
            </Card>
          )}

          {isMovie && (
            <Card title="Files">
              {files.length === 0 ? (
                <p className="text-base-content/60">No files available.</p>
              ) : (
                <ul className="space-y-1">
                  {files.map((file) => (
                    <li key={file.id} className="text-sm text-base-content/70 truncate">
                      {file.streamUrl}
                      {file.size != null && ` (${(file.size / 1_048_576).toFixed(1)} MB)`}
                    </li>
                  ))}
                </ul>
              )}
            </Card>
          )}
        </div>
      </div>

      <Modal ref={deleteModalRef} title="Delete Media" id="delete-media-modal">
        <div className="space-y-4">
          <p>
            Are you sure you want to delete <strong>{title}</strong>? This action
            cannot be undone.
          </p>
          {deleteError && (
            <div className="alert alert-error text-sm">{deleteError}</div>
          )}
          <div className="modal-action">
            <Button
              variant="ghost"
              onClick={() => deleteModalRef.current?.close()}
            >
              Cancel
            </Button>
            <Button
              variant="error"
              loading={deleting}
              onClick={handleDelete}
            >
              Delete
            </Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
