import 'package:flutter/services.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/stack.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:logging/logging.dart';

const String _kHashCancelledCode = "HASH_CANCELLED";

class HashService {
  final int _batchSize;
  final DriftLocalAlbumRepository _localAlbumRepository;
  final DriftLocalAssetRepository _localAssetRepository;
  final DriftTrashedLocalAssetRepository _trashedLocalAssetRepository;
  final NativeSyncApi _nativeSyncApi;
  final DriftStackRepository _stackRepository;
  final AssetApiRepository _assetApiRepository;
  final bool Function()? _cancelChecker;
  final _log = Logger('HashService');

  HashService({
    required this._localAlbumRepository,
    required this._localAssetRepository,
    required this._trashedLocalAssetRepository,
    required this._nativeSyncApi,
    required this._stackRepository,
    required this._assetApiRepository,
    this._cancelChecker,
    int? batchSize,
  }) : _batchSize = batchSize ?? kBatchHashFileLimit;

  bool get isCancelled => _cancelChecker?.call() ?? false;

  Future<void> hashAssets() async {
    _log.info("Starting hashing of assets");
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      // Migrate hashes from cloud ID to local ID so we don't have to re-hash them
      // await _localAssetRepository.reconcileHashesFromCloudId();

      // Sorted by backupSelection followed by isCloud
      final localAlbums = await _localAlbumRepository.getBackupAlbums();
      final hashedIds = <String>{};

      for (final album in localAlbums) {
        if (isCancelled) {
          _log.warning("Hashing cancelled. Stopped processing albums.");
          break;
        }

        final assetsToHash = await _localAlbumRepository.getAssetsToHash(album.id);
        if (assetsToHash.isNotEmpty) {
          await _hashAssets(album, assetsToHash, hashedIds: hashedIds);
        }
      }
      if (CurrentPlatform.isAndroid && localAlbums.isNotEmpty) {
        final backupAlbumIds = localAlbums.map((e) => e.id);
        final trashedToHash = await _trashedLocalAssetRepository.getAssetsToHash(backupAlbumIds);
        if (trashedToHash.isNotEmpty) {
          final pseudoAlbum = LocalAlbum(id: '-pseudoAlbum', name: 'Trash', updatedAt: DateTime.now());
          await _hashAssets(pseudoAlbum, trashedToHash, isTrashed: true, hashedIds: hashedIds);
        }
      }

      // Revert reconcile for non-styled photos: the reverted edit hashes back to the
      // original's exact bytes, which are already the stack base, so it's not a backup
      // candidate and never reaches upload. Flip the primary here. Styled photos
      // re-encode to fresh bytes and get flipped on the upload path instead
      // (EditRevertService.tryHandleRevert).
      if (CurrentPlatform.isIOS && hashedIds.isNotEmpty && !isCancelled) {
        await _reconcileReverts(hashedIds);
      }
    } on PlatformException catch (e) {
      if (e.code == _kHashCancelledCode) {
        _log.warning("Hashing cancelled by platform");
        return;
      }
    } catch (e, s) {
      _log.severe("Error during hashing", e, s);
    }

    stopwatch.stop();
    _log.info("Hashing took - ${stopwatch.elapsedMilliseconds}ms");
  }

  /// Processes a list of [LocalAsset]s, storing their hash and updating the assets in the DB
  /// with hash for those that were successfully hashed. Hashes are looked up in a table
  /// [LocalAssetHashEntity] by local id. Only missing entries are newly hashed and added to the DB.
  Future<void> _hashAssets(
    LocalAlbum album,
    List<LocalAsset> assetsToHash, {
    bool isTrashed = false,
    required Set<String> hashedIds,
  }) async {
    final toHash = <String, LocalAsset>{};

    for (final asset in assetsToHash) {
      if (isCancelled) {
        _log.warning("Hashing cancelled. Stopped processing assets.");
        return;
      }

      toHash[asset.id] = asset;
      if (toHash.length == _batchSize) {
        await _processBatch(album, toHash, isTrashed, hashedIds);
        toHash.clear();
      }
    }

    await _processBatch(album, toHash, isTrashed, hashedIds);
  }

  /// Processes a batch of assets.
  Future<void> _processBatch(
    LocalAlbum album,
    Map<String, LocalAsset> toHash,
    bool isTrashed,
    Set<String> hashedIds,
  ) async {
    if (toHash.isEmpty) {
      return;
    }

    _log.fine("Hashing ${toHash.length} files");

    final hashed = <String, String>{};
    final hashResults = await _nativeSyncApi.hashAssets(
      toHash.keys.toList(),
      allowNetworkAccess: album.backupSelection == BackupSelection.selected,
    );
    assert(
      hashResults.length == toHash.length,
      "Hashes length does not match toHash length: ${hashResults.length} != ${toHash.length}",
    );

    for (int i = 0; i < hashResults.length; i++) {
      if (isCancelled) {
        _log.warning("Hashing cancelled. Stopped processing batch.");
        return;
      }

      final hashResult = hashResults[i];
      if (hashResult.hash != null) {
        hashed[hashResult.assetId] = hashResult.hash!;
      } else {
        final asset = toHash[hashResult.assetId];
        _log.warning(
          "Failed to hash asset with id: ${hashResult.assetId}, name: ${asset?.name}, createdAt: ${asset?.createdAt}, from album: ${album.name}. Error: ${hashResult.error ?? "unknown"}",
        );
      }
    }

    _log.fine("Hashed ${hashed.length}/${toHash.length} assets");
    if (isTrashed) {
      await _trashedLocalAssetRepository.updateHashes(hashed);
    } else {
      await _localAssetRepository.updateHashes(hashed);
    }
    hashedIds.addAll(hashed.keys);
  }

  Future<void> _reconcileReverts(Set<String> localIds) async {
    final List<StackReconcileTarget> targets;
    try {
      targets = await _stackRepository.findRevertReconcileTargets(localIds);
    } catch (error, stack) {
      _log.warning("findRevertReconcileTargets failed", error, stack);
      return;
    }

    for (final target in targets) {
      try {
        await _assetApiRepository.setStackPrimary(target.stackId, target.newPrimaryId);
        await _stackRepository.setPrimary(target.stackId, target.newPrimaryId);
        // Roll priorRemoteId forward to the matched member (now the primary) so a
        // later edit stacks onto THAT (the current render), not the old edit.
        await _localAssetRepository.markSynced(
          target.localAssetId,
          priorRemoteId: target.newPrimaryId,
          syncedChecksum: target.localAssetChecksum,
        );
      } catch (error, stack) {
        _log.warning("revert reconcile flip failed for stack ${target.stackId}", error, stack);
        continue;
      }
    }
  }
}
