import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/stack.repository.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late DriftStackRepository sut;
  late String userId;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = DriftStackRepository(ctx.db);
    final user = await ctx.newUser();
    userId = user.id;
  });

  tearDown(() async {
    await ctx.dispose();
  });

  group('isRemoteTrashed', () {
    test('is false for a live remote', () async {
      await ctx.newRemoteAsset(id: 'live', ownerId: userId);
      expect(await sut.isRemoteTrashed('live'), isFalse);
    });

    test('is false for a remote that was never synced', () async {
      expect(await sut.isRemoteTrashed('missing'), isFalse);
    });

    test('is true only when the synced remote is trashed', () async {
      await ctx.newRemoteAsset(id: 'trashed', ownerId: userId, deletedAt: DateTime(2025, 6));
      expect(await sut.isRemoteTrashed('trashed'), isTrue);
    });
  });

  group('findStackIdByRemoteId', () {
    test('returns the stack id for a stacked remote', () async {
      final base = await ctx.newRemoteAsset(id: 'base', ownerId: userId);
      final stack = await ctx.newStack(ownerId: userId, primaryAssetId: base.id);
      await ctx.newRemoteAsset(id: 'edit', ownerId: userId, stackId: stack.id);
      expect(await sut.findStackIdByRemoteId('edit'), stack.id);
    });

    test('returns null for an unstacked remote', () async {
      await ctx.newRemoteAsset(id: 'lonely', ownerId: userId);
      expect(await sut.findStackIdByRemoteId('lonely'), isNull);
    });

    test('returns null for a trashed remote', () async {
      final base = await ctx.newRemoteAsset(id: 'base', ownerId: userId);
      final stack = await ctx.newStack(ownerId: userId, primaryAssetId: base.id);
      await ctx.newRemoteAsset(id: 'edit', ownerId: userId, stackId: stack.id, deletedAt: DateTime(2025, 6));
      expect(await sut.findStackIdByRemoteId('edit'), isNull);
    });
  });

  group('findStackBaseId', () {
    test('returns the earliest-uploaded member that is not the excluded one', () async {
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: 'edit');
      await ctx.newRemoteAsset(id: 'base', ownerId: userId, stackId: 'stack-1', uploadedAt: DateTime(2025));
      await ctx.newRemoteAsset(id: 'edit', ownerId: userId, stackId: 'stack-1', uploadedAt: DateTime(2025, 2));

      // base uploaded before the edit → it's the flip target.
      expect(await sut.findStackBaseId('stack-1', excludeId: 'edit'), 'base');
    });

    test('returns null when the only member is excluded', () async {
      final base = await ctx.newRemoteAsset(id: 'solo', ownerId: userId, stackId: 'stack-1');
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: base.id);
      expect(await sut.findStackBaseId('stack-1', excludeId: 'solo'), isNull);
    });

    test('skips trashed members', () async {
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: 'edit');
      await ctx.newRemoteAsset(
        id: 'base',
        ownerId: userId,
        stackId: 'stack-1',
        uploadedAt: DateTime(2025),
        deletedAt: DateTime(2025, 6),
      );
      await ctx.newRemoteAsset(id: 'edit', ownerId: userId, stackId: 'stack-1', uploadedAt: DateTime(2025, 2));
      expect(await sut.findStackBaseId('stack-1', excludeId: 'edit'), isNull);
    });
  });

  group('findRevertReconcileTargets', () {
    test('finds a local that hashed back to a non-primary stack member', () async {
      // Stack: primary = edit, also holds base. The local's checksum matches base.
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: 'edit');
      await ctx.newRemoteAsset(id: 'base', ownerId: userId, stackId: 'stack-1', checksum: 'base-sum');
      await ctx.newRemoteAsset(id: 'edit', ownerId: userId, stackId: 'stack-1', checksum: 'edit-sum');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'base-sum', priorRemoteId: 'edit');

      final targets = await sut.findRevertReconcileTargets(['local-1']);

      expect(targets, hasLength(1));
      expect(targets.first.stackId, 'stack-1');
      expect(targets.first.newPrimaryId, 'base');
      expect(targets.first.localAssetId, 'local-1');
    });

    test('returns nothing when the local already matches the primary', () async {
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: 'edit');
      await ctx.newRemoteAsset(id: 'edit', ownerId: userId, stackId: 'stack-1', checksum: 'edit-sum');
      await ctx.newLocalAsset(id: 'local-1', checksum: 'edit-sum', priorRemoteId: 'edit');

      expect(await sut.findRevertReconcileTargets(['local-1']), isEmpty);
    });

    test('ignores a local whose prior remote was trashed', () async {
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: 'edit');
      await ctx.newRemoteAsset(id: 'base', ownerId: userId, stackId: 'stack-1', checksum: 'base-sum');
      await ctx.newRemoteAsset(
        id: 'edit',
        ownerId: userId,
        stackId: 'stack-1',
        checksum: 'edit-sum',
        deletedAt: DateTime(2025, 6),
      );
      await ctx.newLocalAsset(id: 'local-1', checksum: 'base-sum', priorRemoteId: 'edit');

      expect(await sut.findRevertReconcileTargets(['local-1']), isEmpty);
    });

    test('returns nothing for an empty id set', () async {
      expect(await sut.findRevertReconcileTargets(const []), isEmpty);
    });
  });
}
