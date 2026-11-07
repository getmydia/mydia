export interface SourceTile {
  id: 'mydia' | 'plex' | 'jellyfin' | 'folders';
  name: string;
  status: 'available' | 'soon';
}

export const sources: SourceTile[] = [
  { id: 'mydia', name: 'Mydia Server', status: 'available' },
  { id: 'plex', name: 'Plex', status: 'available' },
  { id: 'jellyfin', name: 'Jellyfin', status: 'available' },
  { id: 'folders', name: 'Local folders', status: 'soon' },
];
