import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/edit_revert.service.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:mocktail/mocktail.dart';

import '../mocks.dart';

void main() {
  late EditRevertService sut;
  final mocks = UnitMocks();

  LocalAsset asset({String? priorRemoteId, String? checksum = 'reverted-sha1'}) => LocalAsset(
    id: 'local-1',
    name: 'photo.jpg',
    type: AssetType.image,
    createdAt: DateTime(2025),
    updatedAt: DateTime(2025, 2),
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: false,
    priorRemoteId: priorRemoteId,
    checksum: checksum,
  );

  setUp(() {
    sut = EditRevertService(
      nativeSyncApi: mocks.nativeApi,
      stackRepository: mocks.stack,
      localAssetRepository: mocks.localAsset,
      assetApiRepository: mocks.assetApi,
    );
  });

  tearDown(() {
    mocks.reset();
  });

  group('tryHandleRevert', () {
    test('returns false when the asset was never uploaded as an edit', () async {
      expect(await sut.tryHandleRevert(asset(priorRemoteId: null)), isFalse);
      verifyNever(() => mocks.nativeApi.getEditState(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('returns false (lets the pair flow run) when there is still a live edit', () async {
      when(
        () => mocks.nativeApi.getEditState('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer((_) async => EditState.edited);

      expect(await sut.tryHandleRevert(asset(priorRemoteId: 'remote-edit')), isFalse);
      verifyNever(() => mocks.stack.findStackIdByRemoteId(any()));
    });

    test('returns false when the edit state cannot be read (offloaded to iCloud)', () async {
      when(
        () => mocks.nativeApi.getEditState('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer((_) async => EditState.unknown);

      expect(await sut.tryHandleRevert(asset(priorRemoteId: 'remote-edit')), isFalse);
      verifyNever(() => mocks.stack.findStackIdByRemoteId(any()));
    });

    test('returns false when the prior remote is not in a stack', () async {
      when(
        () => mocks.nativeApi.getEditState('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer((_) async => EditState.notEdited);
      when(() => mocks.stack.findStackIdByRemoteId('remote-edit')).thenAnswer((_) async => null);

      expect(await sut.tryHandleRevert(asset(priorRemoteId: 'remote-edit')), isFalse);
      verifyNever(() => mocks.assetApi.setStackPrimary(any(), any()));
    });

    test('returns false when the stack has no base member to flip back to', () async {
      when(
        () => mocks.nativeApi.getEditState('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer((_) async => EditState.notEdited);
      when(() => mocks.stack.findStackIdByRemoteId('remote-edit')).thenAnswer((_) async => 'stack-1');
      when(() => mocks.stack.findStackBaseId('stack-1', excludeId: 'remote-edit')).thenAnswer((_) async => null);

      expect(await sut.tryHandleRevert(asset(priorRemoteId: 'remote-edit')), isFalse);
      verifyNever(() => mocks.assetApi.setStackPrimary(any(), any()));
    });

    test('flips the primary back to the base via prior_remote_id and keeps the edit (no trash)', () async {
      when(
        () => mocks.nativeApi.getEditState('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer((_) async => EditState.notEdited);
      when(() => mocks.stack.findStackIdByRemoteId('remote-edit')).thenAnswer((_) async => 'stack-1');
      when(
        () => mocks.stack.findStackBaseId('stack-1', excludeId: 'remote-edit'),
      ).thenAnswer((_) async => 'remote-base');
      when(() => mocks.assetApi.setStackPrimary('stack-1', 'remote-base')).thenAnswer((_) async {});
      when(() => mocks.stack.setPrimary('stack-1', 'remote-base')).thenAnswer((_) async {});
      when(
        () => mocks.localAsset.markSynced(
          'local-1',
          priorRemoteId: 'remote-base',
          syncedChecksum: any(named: 'syncedChecksum'),
        ),
      ).thenAnswer((_) async {});

      expect(await sut.tryHandleRevert(asset(priorRemoteId: 'remote-edit')), isTrue);

      verify(() => mocks.assetApi.setStackPrimary('stack-1', 'remote-base')).called(1);
      verify(() => mocks.stack.setPrimary('stack-1', 'remote-base')).called(1);
      verify(
        () => mocks.localAsset.markSynced(
          'local-1',
          priorRemoteId: 'remote-base',
          syncedChecksum: any(named: 'syncedChecksum'),
        ),
      ).called(1);
      // Nothing is trashed or unstacked; every edit stays in the stack.
      verifyNever(() => mocks.assetApi.delete(any(), any()));
      verifyNever(() => mocks.assetApi.unStack(any()));
    });
  });
}
