import { useQuery } from "urql";
import { DashboardStatsDocument } from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";

const STAT_LABELS: Record<string, string> = {
  totalMovies: "Movies",
  totalTvShows: "TV Shows",
  totalEpisodes: "Episodes",
  watchedEpisodes: "Watched Episodes",
  totalLibraries: "Libraries",
  missingEpisodes: "Missing Episodes",
  monitoredMovies: "Monitored Movies",
  monitoredTvShows: "Monitored TV Shows",
};

export function DashboardPage() {
  const [{ data, fetching, error }] = useQuery({ query: DashboardStatsDocument });
  const stats = data?.dashboardStats;

  if (error) {
    return (
      <div>
        <PageHeader title="Dashboard" />
        <div className="alert alert-error">
          Failed to load dashboard data.
        </div>
      </div>
    );
  }

  return (
    <div>
      <PageHeader title="Dashboard" subtitle="Overview of your media library" />

      {fetching && !stats ? (
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      ) : (
        <>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4 mb-8">
            {stats &&
              Object.entries(STAT_LABELS).map(([key, label]) => (
                <div key={key} className="card bg-base-100 shadow">
                  <div className="card-body p-5">
                    <h3 className="text-sm text-base-content/60">{label}</h3>
                    <p className="text-2xl font-bold">
                      {(stats as Record<string, number>)[key] ?? "--"}
                    </p>
                  </div>
                </div>
              ))}
          </div>

          <Card title="Getting Started" subtitle="Your media management hub">
            <div className="space-y-3">
              <p className="text-base-content/70">
                Use the sidebar to browse your library, discover new content, or
                manage your requests.
              </p>
              <div className="flex flex-wrap gap-2">
                <a href="/discover" className="btn btn-primary btn-sm">
                  Discover
                </a>
                <a href="/calendar" className="btn btn-outline btn-sm">
                  Calendar
                </a>
                <a href="/my-requests" className="btn btn-outline btn-sm">
                  My Requests
                </a>
              </div>
            </div>
          </Card>
        </>
      )}
    </div>
  );
}
