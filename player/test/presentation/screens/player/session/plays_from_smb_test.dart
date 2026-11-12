import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/presentation/screens/player/session/source_playback_sessions.dart';

Source _source(String accountId, SourceKind kind) => Source(
      account: ProviderAccount(
        id: accountId,
        kind: kind,
        displayName: 'x',
        storageNamespace: 'source/$accountId',
        activeProfileId: kOwnerProfileId,
      ),
      profile: SourceProfile(
        id: kOwnerProfileId,
        accountId: accountId,
        name: 'Owner',
        isOwner: true,
      ),
      server: SourceServer(
        id: accountId,
        accountId: accountId,
        profileId: kOwnerProfileId,
        name: 'x',
      ),
    );

void main() {
  test('an SMB files source plays from SMB', () {
    final id = smbAccountId(Uri.parse('smb://nas.local/media'));
    expect(isSmbSource(_source(id, SourceKind.files)), isTrue);
  });

  test('a WebDAV files source does not', () {
    expect(isSmbSource(_source('wabcdef', SourceKind.files)), isFalse);
    expect(
        isSmbSource(_source(kFilesLocalAccountId, SourceKind.files)), isFalse);
  });

  test('a Mydia source does not', () {
    expect(isSmbSource(_source('macct', SourceKind.mydia)), isFalse);
  });
}
