import 'dart:io';

import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/stack.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:logging/logging.dart';

/// What to do with an edited iOS photo when backing it up.
sealed class EditPairPlan {
  const EditPairPlan();
}

/// Not something we stack: not edited, identical bytes, or couldn't read it.
class NoEditPair extends EditPairPlan {
  const NoEditPair();
}

/// Already uploaded before; stack the edit onto that remote id.
class AbsorbIntoPrior extends EditPairPlan {
  final String parentId;
  const AbsorbIntoPrior(this.parentId);
}

/// Upload the original first; [base] is its temp file.
class UploadBaseFirst extends EditPairPlan {
  final BaseResource base;
  const UploadBaseFirst(this.base);
}

/// Works out how an edited photo should stack: reuse a prior upload, upload the
/// original first, or do nothing. Shared by the foreground and background upload
/// paths. The caller already checked it's iOS and not a live photo.
///
/// A photo that was never edited only carries the capture-time Photographic Style,
/// which iOS stamps at [LocalAsset.createdAt]; a real edit moves [LocalAsset.adjustmentTime]
/// later. When they match (or there's no adjustment at all) there's nothing to stack, so
/// we skip the native read. Anything that moved the timestamp (edit, retime, revert) falls
/// through to [NativeSyncApi.getBaseResource], which reads the adjustment plist and decides.
Future<EditPairPlan> resolveEditPair(
  NativeSyncApi nativeSyncApi,
  LocalAsset asset, {
  required DriftStackRepository stackRepository,
  Logger? log,
}) async {
  final priorRemoteId = asset.priorRemoteId;
  if (priorRemoteId != null) {
    // Reuse the prior upload unless it was trashed on the server. A dead parent
    // makes the edit upload 400 ("Cannot stack onto a trashed or missing asset")
    // forever; fall through to uploading the base again so the stack rebuilds.
    bool priorTrashed;
    try {
      priorTrashed = await stackRepository.isRemoteTrashed(priorRemoteId);
    } catch (error, stack) {
      log?.warning(() => "Failed to check prior remote $priorRemoteId for ${asset.id}", error, stack);
      priorTrashed = false;
    }
    if (!priorTrashed) {
      return AbsorbIntoPrior(priorRemoteId);
    }
  }

  if (!_mightBeEdited(asset)) {
    return const NoEditPair();
  }

  BaseResource? base;
  try {
    base = await nativeSyncApi.getBaseResource(asset.id, allowNetworkAccess: true);
  } catch (error, stack) {
    log?.warning(() => "Failed to read base resource for ${asset.id}", error, stack);
    return const NoEditPair();
  }
  if (base == null) {
    return const NoEditPair();
  }

  // Identical bytes (e.g. auto-HDR), nothing real to stack. Drop the temp copy.
  if (base.sha1 == asset.checksum) {
    try {
      await File(base.path).delete();
    } catch (_) {}
    return const NoEditPair();
  }

  return UploadBaseFirst(base);
}

/// iOS stamps the capture-time Photographic Style at the creation time and moves the
/// adjustment timestamp on any later change. A gap past a small tolerance (capture jitter
/// is sub-second, real edits are seconds apart) is worth a native check; no adjustment at
/// all means the photo was never touched.
bool _mightBeEdited(LocalAsset asset) {
  final adjustedAt = asset.adjustmentTime;
  if (adjustedAt == null) {
    return false;
  }
  return adjustedAt.difference(asset.createdAt).inSeconds.abs() > _editTimestampToleranceSeconds;
}

const _editTimestampToleranceSeconds = 2;
