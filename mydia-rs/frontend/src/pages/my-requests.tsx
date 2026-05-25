import { useQuery } from "urql";
import { MyRequestsDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { StatusPill } from "../components/status-pill";

export function MyRequestsPage() {
  const [{ data, fetching, error }] = useQuery({ query: MyRequestsDocument });
  const requests = data?.myRequests ?? [];

  return (
    <div>
      <PageHeader
        title="My Requests"
        subtitle="Media you have requested"
        actions={
          <a href="/request-media" className="btn btn-primary btn-sm">
            New Request
          </a>
        }
      />

      {error && (
        <div className="alert alert-error mb-4">
          Failed to load requests.
        </div>
      )}

      {fetching && requests.length === 0 ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : requests.length === 0 ? (
        <Card>
          <p className="text-base-content/60">
            You haven&apos;t made any requests yet.
          </p>
          <div className="card-actions mt-4">
            <a href="/request-media" className="btn btn-primary btn-sm">
              Request Media
            </a>
          </div>
        </Card>
      ) : (
        <div className="space-y-3">
          {requests.map((req) => (
            <Card key={req.id} className="hover:bg-base-200/50 transition-colors">
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0 flex-1">
                  <h3 className="font-semibold truncate">{req.title}</h3>
                  <p className="text-sm text-base-content/60">
                    {req.year ?? "---"} &middot; {req.mediaType}
                  </p>
                  {req.requesterNotes && (
                    <p className="text-sm text-base-content/70 mt-1 line-clamp-2">
                      {req.requesterNotes}
                    </p>
                  )}
                </div>
                <StatusPill status={req.status} />
              </div>
              {req.adminNotes && (
                <div className="mt-2 p-2 bg-base-200 rounded text-sm">
                  <span className="font-medium">Admin notes:</span>{" "}
                  {req.adminNotes}
                </div>
              )}
              {req.rejectionReason && (
                <div className="mt-2 p-2 bg-error/10 rounded text-sm text-error">
                  {req.rejectionReason}
                </div>
              )}
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
