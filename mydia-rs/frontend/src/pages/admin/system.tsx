import { useQuery } from "urql";
import { SystemStatusDocument } from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { ConfigSection, StatRow } from "../../components/config-form";
import { StatusPill } from "../../components/status-pill";
import { Button } from "../../components/button";
import { Alert } from "../../components/feedback";

export function SystemPage() {
  const [result, refetch] = useQuery({ query: SystemStatusDocument });

  const data = result.data?.systemStatus;
  const error = result.error;

  if (result.fetching && !data) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="System"
        subtitle="Server health, database status, and setup counts"
        actions={
          <Button size="sm" variant="ghost" onClick={() => refetch()}>
            Refresh
          </Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load system status">
          {error.message}
        </Alert>
      )}

      {data && (
        <>
          <ConfigSection
            id="admin-system-process"
            title="Process"
            description="Build, target, and uptime for this Mydia node."
          >
            <StatRow label="App version" value={data.appVersion} />
            <StatRow label="Build target" value={data.buildTarget} />
            <StatRow label="Uptime" value={data.uptime} />
          </ConfigSection>

          <ConfigSection
            id="admin-system-database"
            title="Database"
            description="Adapter, location, and current pool health."
            actions={
              <StatusPill
                status={
                  data.databaseHealth === "healthy" ? "active" : "error"
                }
                label={data.databaseHealth}
              />
            }
          >
            <StatRow label="Adapter" value={data.databaseAdapter} />
            <StatRow label="Location" value={data.databaseLocation} />
            <StatRow label="Size" value={data.databaseSize} />
          </ConfigSection>

          <ConfigSection
            id="admin-system-pipeline"
            title="Pipeline"
            description="Active counts for the workers operators reach for first."
          >
            <StatRow
              label="Library paths"
              value={String(data.libraryPathsCount)}
            />
            <StatRow
              label="Download clients"
              value={String(data.downloadClientsCount)}
            />
            <StatRow
              label="Indexers"
              value={String(data.indexersCount)}
            />
            <StatRow
              label="Active transcodes"
              value={String(data.activeTranscodes)}
            />
            <StatRow
              label="Streaming sessions"
              value={String(data.activeStreamingSessions)}
            />
          </ConfigSection>

          <ConfigSection
            id="admin-system-setup"
            title="Setup"
            description="Summary counts for verifying a fresh installation."
          >
            <StatRow
              label="Users"
              value={String(data.setupCounts.userCount)}
            />
            <StatRow
              label="Media items"
              value={String(data.setupCounts.mediaCount)}
            />
            <StatRow
              label="Library paths"
              value={String(data.setupCounts.libraryPathCount)}
            />
          </ConfigSection>
        </>
      )}
    </div>
  );
}
