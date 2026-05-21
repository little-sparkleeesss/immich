import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/infrastructure/entities/stack.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

class StackReconcileTarget {
  final String stackId;
  final String newPrimaryId;
  final String localAssetId;
  final String localAssetChecksum;

  const StackReconcileTarget({
    required this.stackId,
    required this.newPrimaryId,
    required this.localAssetId,
    required this.localAssetChecksum,
  });
}

class DriftStackRepository extends DriftDatabaseRepository {
  final Drift _db;
  const DriftStackRepository(this._db) : super(_db);

  Future<List<Stack>> getAll(String userId) {
    final query = _db.stackEntity.select()..where((e) => e.ownerId.equals(userId));

    return query.map((stack) {
      return stack.toDto();
    }).get();
  }

  // Per local id, find a stack member whose checksum matches the local's current
  // checksum but isn't the stack primary. That's the revert case: the local hashed
  // back to the base while the primary still points at the edit.
  Future<List<StackReconcileTarget>> findRevertReconcileTargets(Iterable<String> localAssetIds) async {
    final ids = localAssetIds.toSet();
    if (ids.isEmpty) {
      return const [];
    }

    final targets = <StackReconcileTarget>[];
    for (final slice in ids.slices(kDriftMaxChunk)) {
      final placeholders = List.filled(slice.length, '?').join(',');
      final rows = await _db
          .customSelect(
            '''
        SELECT
          s.id AS stack_id,
          member.id AS new_primary,
          local.id AS local_id,
          local.checksum AS local_checksum
        FROM local_asset_entity local
        INNER JOIN remote_asset_entity prior ON prior.id = local.prior_remote_id AND prior.deleted_at IS NULL
        INNER JOIN stack_entity s ON s.id = prior.stack_id
        INNER JOIN remote_asset_entity member
          ON member.stack_id = s.id
          AND member.checksum = local.checksum
          AND member.deleted_at IS NULL
        WHERE local.id IN ($placeholders)
          AND s.primary_asset_id != member.id
        ''',
            variables: slice.map((id) => Variable<String>(id)).toList(),
            readsFrom: {_db.localAssetEntity, _db.remoteAssetEntity, _db.stackEntity},
          )
          .get();

      for (final row in rows) {
        targets.add(
          StackReconcileTarget(
            stackId: row.read<String>('stack_id'),
            newPrimaryId: row.read<String>('new_primary'),
            localAssetId: row.read<String>('local_id'),
            localAssetChecksum: row.read<String>('local_checksum'),
          ),
        );
      }
    }
    return targets;
  }

  // True only when we have positive evidence the remote was trashed: a synced
  // row exists with deleted_at set. A missing row returns false on purpose — a
  // just-uploaded prior isn't synced into remote_asset_entity yet, and treating
  // "not synced" as "dead" would re-upload a duplicate base every cycle until
  // the next remote sync lands.
  Future<bool> isRemoteTrashed(String remoteId) async {
    final row = await _db
        .customSelect(
          'SELECT 1 FROM remote_asset_entity WHERE id = ? AND deleted_at IS NOT NULL LIMIT 1',
          variables: [Variable<String>(remoteId)],
          readsFrom: {_db.remoteAssetEntity},
        )
        .getSingleOrNull();
    return row != null;
  }

  // The stack a remote asset belongs to, if any. Used by the revert path to find
  // the stack from prior_remote_id when the reverted bytes can't be checksum-matched.
  Future<String?> findStackIdByRemoteId(String remoteId) async {
    final row = await _db
        .customSelect(
          'SELECT stack_id FROM remote_asset_entity WHERE id = ? AND stack_id IS NOT NULL AND deleted_at IS NULL',
          variables: [Variable<String>(remoteId)],
          readsFrom: {_db.remoteAssetEntity},
        )
        .getSingleOrNull();
    return row?.read<String?>('stack_id');
  }

  // The stack's original base member to flip back to on revert: the earliest-
  // uploaded member that isn't the (latest-edit) prior. The base is uploaded
  // before its edits, so oldest uploaded_at = the original.
  Future<String?> findStackBaseId(String stackId, {required String excludeId}) async {
    final row = await _db
        .customSelect(
          '''
          SELECT id FROM remote_asset_entity
          WHERE stack_id = ? AND id != ? AND deleted_at IS NULL
          ORDER BY uploaded_at IS NULL, uploaded_at ASC, id ASC
          LIMIT 1
          ''',
          variables: [Variable<String>(stackId), Variable<String>(excludeId)],
          readsFrom: {_db.remoteAssetEntity},
        )
        .getSingleOrNull();
    return row?.read<String?>('id');
  }

  // Optimistic local primary flip so the timeline updates immediately; the
  // server's stack-update websocket rewrites it shortly after.
  Future<void> setPrimary(String stackId, String primaryAssetId) {
    return (_db.stackEntity.update()..where((e) => e.id.equals(stackId))).write(
      StackEntityCompanion(primaryAssetId: Value(primaryAssetId)),
    );
  }
}

extension on StackEntityData {
  Stack toDto() {
    return Stack(id: id, createdAt: createdAt, updatedAt: updatedAt, ownerId: ownerId, primaryAssetId: primaryAssetId);
  }
}
