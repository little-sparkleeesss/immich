import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/services/edit_pair.dart';
import 'package:mocktail/mocktail.dart';

import '../mocks.dart';

void main() {
  final mocks = UnitMocks();

  // createdAt fixed; adjustmentTime is what moves a real edit past the gate.
  LocalAsset asset({DateTime? adjustmentTime, String? priorRemoteId, String? checksum = 'local-sha1'}) => LocalAsset(
    id: 'local-1',
    name: 'photo.jpg',
    type: AssetType.image,
    createdAt: DateTime(2025, 1, 1, 12),
    updatedAt: DateTime(2025, 1, 1, 12),
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: false,
    adjustmentTime: adjustmentTime,
    priorRemoteId: priorRemoteId,
    checksum: checksum,
  );

  BaseResource base(String sha1) => BaseResource(path: '/tmp/none', sha1: sha1, sizeBytes: 1, mimeType: 'image/jpeg');

  void stubBase(BaseResource? result) {
    when(
      () => mocks.nativeApi.getBaseResource('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
    ).thenAnswer((_) async => result);
  }

  Future<EditPairPlan> resolve(LocalAsset asset) =>
      resolveEditPair(mocks.nativeApi, asset, stackRepository: mocks.stack);

  setUp(() {
    // Default: the prior remote is alive, so absorb is allowed.
    when(() => mocks.stack.isRemoteTrashed(any())).thenAnswer((_) async => false);
  });

  tearDown(() {
    mocks.reset();
  });

  group('resolveEditPair', () {
    test('reuses the prior remote when the asset was already uploaded as an edit', () async {
      final plan = await resolve(asset(priorRemoteId: 'remote-edit'));

      expect(plan, isA<AbsorbIntoPrior>().having((p) => p.parentId, 'parentId', 'remote-edit'));
      verifyNever(() => mocks.nativeApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('uploads the base instead of absorbing when the prior remote was trashed', () async {
      when(() => mocks.stack.isRemoteTrashed('remote-edit')).thenAnswer((_) async => true);
      stubBase(base('different-sha1'));

      final plan = await resolve(asset(priorRemoteId: 'remote-edit', adjustmentTime: DateTime(2025, 1, 1, 12, 0, 30)));

      expect(plan, isA<UploadBaseFirst>());
    });

    test('does not absorb a trashed prior even when the asset reads as not edited', () async {
      when(() => mocks.stack.isRemoteTrashed('remote-edit')).thenAnswer((_) async => true);

      // Trashed prior + no adjustment → falls through to the gate, which skips.
      final plan = await resolve(asset(priorRemoteId: 'remote-edit', adjustmentTime: null));

      expect(plan, isA<NoEditPair>());
    });

    test('absorbs the prior when the trashed check itself fails (cheap-path safety)', () async {
      when(() => mocks.stack.isRemoteTrashed('remote-edit')).thenThrow(Exception('db error'));

      final plan = await resolve(asset(priorRemoteId: 'remote-edit'));

      expect(plan, isA<AbsorbIntoPrior>().having((p) => p.parentId, 'parentId', 'remote-edit'));
    });

    test('skips a photo that was never adjusted without touching native', () async {
      final plan = await resolve(asset(adjustmentTime: null));

      expect(plan, isA<NoEditPair>());
      verifyNever(() => mocks.nativeApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('skips a capture-time style (adjustment within the 2s window)', () async {
      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 1)));

      expect(plan, isA<NoEditPair>());
      verifyNever(() => mocks.nativeApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('skips at exactly the 2s boundary (tolerance is exclusive)', () async {
      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 2)));

      expect(plan, isA<NoEditPair>());
      verifyNever(() => mocks.nativeApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('checks the original just past the 2s boundary', () async {
      stubBase(base('different-sha1'));

      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 3)));

      expect(plan, isA<UploadBaseFirst>());
      verify(() => mocks.nativeApi.getBaseResource('local-1', allowNetworkAccess: true)).called(1);
    });

    test('uploads the original first when a real edit moved the timestamp', () async {
      stubBase(base('different-sha1'));

      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 30)));

      expect(plan, isA<UploadBaseFirst>());
      verify(() => mocks.nativeApi.getBaseResource('local-1', allowNetworkAccess: true)).called(1);
    });

    test('skips when the original cannot be read (offloaded to iCloud)', () async {
      stubBase(null);

      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 30)));

      expect(plan, isA<NoEditPair>());
    });

    test('skips when the original bytes match the asset (auto-HDR, nothing to stack)', () async {
      stubBase(base('local-sha1'));

      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 30)));

      expect(plan, isA<NoEditPair>());
    });

    test('skips when reading the original throws', () async {
      when(
        () => mocks.nativeApi.getBaseResource('local-1', allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenThrow(Exception('boom'));

      final plan = await resolve(asset(adjustmentTime: DateTime(2025, 1, 1, 12, 0, 30)));

      expect(plan, isA<NoEditPair>());
    });
  });
}
