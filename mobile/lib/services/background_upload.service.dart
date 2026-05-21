import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/edit_revert.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/stack.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/stack.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/edit_pair.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final backgroundUploadServiceProvider = Provider((ref) {
  final service = BackgroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    ref.watch(localAssetRepository),
    ref.watch(backupRepositoryProvider),
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(nativeSyncApiProvider),
    ref.watch(editRevertServiceProvider),
    ref.watch(driftStackProvider),
  );

  ref.onDispose(service.dispose);
  return service;
});

/// Metadata for upload tasks to track live photo handling
class UploadTaskMetadata {
  final String localAssetId;
  final bool isLivePhotos;
  final String livePhotoVideoId;

  // Marks the base upload of an edit pair. On completion the chained edit
  // upload is enqueued with stackParentId = this base's remote id.
  final bool isEditPair;

  // Path of the native temp file backing this task (the edit base), so it can
  // be cleaned up on terminal status.
  final String basePath;

  const UploadTaskMetadata({
    required this.localAssetId,
    required this.isLivePhotos,
    required this.livePhotoVideoId,
    this.isEditPair = false,
    this.basePath = '',
  });

  UploadTaskMetadata copyWith({
    String? localAssetId,
    bool? isLivePhotos,
    String? livePhotoVideoId,
    bool? isEditPair,
    String? basePath,
  }) {
    return UploadTaskMetadata(
      localAssetId: localAssetId ?? this.localAssetId,
      isLivePhotos: isLivePhotos ?? this.isLivePhotos,
      livePhotoVideoId: livePhotoVideoId ?? this.livePhotoVideoId,
      isEditPair: isEditPair ?? this.isEditPair,
      basePath: basePath ?? this.basePath,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'localAssetId': localAssetId,
      'isLivePhotos': isLivePhotos,
      'livePhotoVideoId': livePhotoVideoId,
      'isEditPair': isEditPair,
      'basePath': basePath,
    };
  }

  factory UploadTaskMetadata.fromMap(Map<String, dynamic> map) {
    return UploadTaskMetadata(
      localAssetId: map['localAssetId'] as String,
      isLivePhotos: map['isLivePhotos'] as bool,
      livePhotoVideoId: map['livePhotoVideoId'] as String,
      isEditPair: (map['isEditPair'] as bool?) ?? false,
      basePath: (map['basePath'] as String?) ?? '',
    );
  }

  String toJson() => json.encode(toMap());

  factory UploadTaskMetadata.fromJson(String source) =>
      UploadTaskMetadata.fromMap(json.decode(source) as Map<String, dynamic>);

  @override
  String toString() =>
      'UploadTaskMetadata(localAssetId: $localAssetId, isLivePhotos: $isLivePhotos, livePhotoVideoId: $livePhotoVideoId, isEditPair: $isEditPair, basePath: $basePath)';

  @override
  bool operator ==(covariant UploadTaskMetadata other) {
    if (identical(this, other)) {
      return true;
    }

    return other.localAssetId == localAssetId &&
        other.isLivePhotos == isLivePhotos &&
        other.livePhotoVideoId == livePhotoVideoId &&
        other.isEditPair == isEditPair &&
        other.basePath == basePath;
  }

  @override
  int get hashCode =>
      localAssetId.hashCode ^
      isLivePhotos.hashCode ^
      livePhotoVideoId.hashCode ^
      isEditPair.hashCode ^
      basePath.hashCode;
}

/// Service for handling background uploads using iOS URLSession (background_downloader)
///
/// This service handles asynchronous background uploads that can continue
/// even when the app is suspended. Primarily used for iOS background backup.
class BackgroundUploadService {
  BackgroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._localAssetRepository,
    this._backupRepository,
    this._assetMediaRepository,
    this._nativeSyncApi,
    this._editRevertService,
    this._stackRepository,
  ) {
    _uploadRepository.onUploadStatus = _onUploadCallback;
    _uploadRepository.onTaskProgress = _onTaskProgressCallback;
  }

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final DriftLocalAssetRepository _localAssetRepository;
  final DriftBackupRepository _backupRepository;
  final AssetMediaRepository _assetMediaRepository;
  final NativeSyncApi _nativeSyncApi;
  final EditRevertService _editRevertService;
  final DriftStackRepository _stackRepository;
  final Logger _logger = Logger('BackgroundUploadService');

  final StreamController<TaskStatusUpdate> _taskStatusController = StreamController<TaskStatusUpdate>.broadcast();
  final StreamController<TaskProgressUpdate> _taskProgressController = StreamController<TaskProgressUpdate>.broadcast();

  Stream<TaskStatusUpdate> get taskStatusStream => _taskStatusController.stream;
  Stream<TaskProgressUpdate> get taskProgressStream => _taskProgressController.stream;

  bool shouldAbortQueuingTasks = false;

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (!_taskProgressController.isClosed) {
      _taskProgressController.add(update);
    }
  }

  void _onUploadCallback(TaskStatusUpdate update) {
    if (!_taskStatusController.isClosed) {
      _taskStatusController.add(update);
    }
    _handleTaskStatusUpdate(update);
  }

  void dispose() {
    _taskStatusController.close();
    _taskProgressController.close();
  }

  /// Enqueue tasks to the background upload queue
  Future<List<bool>> enqueueTasks(List<UploadTask> tasks) {
    return _uploadRepository.enqueueBackgroundAll(tasks);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return _uploadRepository.getActiveTasks(group);
  }

  /// Start background upload using iOS URLSession
  ///
  /// Finds backup candidates, builds upload tasks, and enqueues them
  /// for background processing.
  Future<void> uploadBackupCandidates(String userId) async {
    await _storageRepository.clearCache();
    shouldAbortQueuingTasks = false;

    final candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      _logger.info("No new backup candidates found, finishing background upload");
      return;
    }

    _logger.info("Found ${candidates.length} backup candidates for background tasks");

    const batchSize = 100;
    final batch = candidates.take(batchSize).toList();
    List<UploadTask> tasks = [];

    for (final asset in batch) {
      final task = await getUploadTask(asset);
      if (task != null) {
        tasks.add(task);
      }
    }

    if (tasks.isNotEmpty && !shouldAbortQueuingTasks) {
      _logger.info("Enqueuing ${tasks.length} background upload tasks");
      await enqueueTasks(tasks);
    }
  }

  /// Cancel all ongoing background uploads and reset the upload queue
  ///
  /// Returns the number of tasks left in the queue
  Future<int> cancel() async {
    shouldAbortQueuingTasks = true;

    await _storageRepository.clearCache();
    await _uploadRepository.reset(kBackupGroup);
    await _uploadRepository.reset(kBackupEditPairGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupEditPairGroup);

    final activeTasks = await _uploadRepository.getActiveTasks(kBackupGroup);
    final activeEditTasks = await _uploadRepository.getActiveTasks(kBackupEditPairGroup);
    return activeTasks.length + activeEditTasks.length;
  }

  /// Resume background backup processing
  Future<void> resume() {
    return _uploadRepository.start();
  }

  void _handleTaskStatusUpdate(TaskStatusUpdate update) async {
    UploadTaskMetadata? metadata;
    if (update.task.metaData.isNotEmpty) {
      try {
        metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      } catch (_) {
        metadata = null;
      }
    }

    switch (update.status) {
      case TaskStatus.complete:
        unawaited(_handleLivePhoto(update, metadata));
        unawaited(handleEditPair(update, metadata));
        unawaited(recordPriorRemoteIdOnSuccess(update, metadata));

        // Edit-pair bases live in the native temp dir and are deleted by
        // handleEditPair via metadata.basePath; deleting here too just races it
        // and logs a spurious SEVERE on the loser.
        if (CurrentPlatform.isIOS && !(metadata?.isEditPair ?? false)) {
          try {
            final path = await update.task.filePath();
            await File(path).delete();
          } catch (e) {
            _logger.severe('Error deleting file path for iOS: $e');
          }
        }

        break;

      case TaskStatus.failed:
      case TaskStatus.canceled:
      case TaskStatus.notFound:
        unawaited(_cleanupTempResourceOnFailure(metadata));
        break;

      default:
        break;
    }
  }

  Future<void> _handleLivePhoto(TaskStatusUpdate update, UploadTaskMetadata? metadata) async {
    try {
      if (metadata == null || !metadata.isLivePhotos) {
        return;
      }

      if (update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }
      final response = jsonDecode(update.responseBody!);

      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return;
      }

      final uploadTask = await getLivePhotoUploadTask(localAsset, response['id'] as String);

      if (uploadTask == null) {
        return;
      }

      await enqueueTasks([uploadTask]);
    } catch (error, stackTrace) {
      dPrint(() => "Error handling live photo upload task: $error $stackTrace");
    }
  }

  /// When an edit-pair base upload finishes, enqueue the edit on top of it
  /// (stackParentId = the base's new remote id).
  @visibleForTesting
  Future<void> handleEditPair(TaskStatusUpdate update, UploadTaskMetadata? metadata) async {
    try {
      if (metadata == null || !metadata.isEditPair) {
        return;
      }
      if (metadata.basePath.isNotEmpty) {
        try {
          await File(metadata.basePath).delete();
        } catch (_) {}
      }
      final baseRemoteId = _remoteIdFromResponse(update);
      if (baseRemoteId == null) {
        return;
      }
      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return;
      }
      final editTask = await getEditUploadTask(localAsset, baseRemoteId);
      if (editTask != null) {
        await enqueueTasks([editTask]);
      }
    } catch (error, stackTrace) {
      dPrint(() => "Error handling edit pair task: $error $stackTrace");
    }
  }

  /// Saves the uploaded remote id as the asset's priorRemoteId so a later edit
  /// stacks onto it. Skipped for edit-pair base uploads; the chained edit records it.
  @visibleForTesting
  Future<void> recordPriorRemoteIdOnSuccess(TaskStatusUpdate update, UploadTaskMetadata? metadata) async {
    try {
      if (metadata == null || metadata.isEditPair || metadata.isLivePhotos || metadata.localAssetId.isEmpty) {
        return;
      }
      final remoteId = _remoteIdFromResponse(update);
      if (remoteId == null) {
        return;
      }
      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      await _localAssetRepository.markSynced(
        metadata.localAssetId,
        priorRemoteId: remoteId,
        syncedChecksum: localAsset?.checksum,
      );
    } catch (error, stackTrace) {
      dPrint(() => "Error recording priorRemoteId: $error $stackTrace");
    }
  }

  Future<void> _cleanupTempResourceOnFailure(UploadTaskMetadata? metadata) async {
    if (metadata == null || metadata.basePath.isEmpty) {
      return;
    }
    try {
      await File(metadata.basePath).delete();
    } catch (_) {}
  }

  /// The new asset's remote id from an upload's response body, or null if the
  /// body is missing/malformed.
  String? _remoteIdFromResponse(TaskStatusUpdate update) {
    final body = update.responseBody;
    if (body == null || body.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(body)['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<UploadTask> _buildBaseUploadTask(LocalAsset asset, BaseResource base) async {
    final metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      isLivePhotos: false,
      livePhotoVideoId: '',
      isEditPair: true,
      basePath: base.path,
    ).toJson();

    // The base is the unedited original (no adjustmentTime); the `_base`
    // deviceAssetId keeps it distinct from the chained edit task.
    return buildUploadTask(
      File(base.path),
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: p.setExtension(asset.name, p.extension(base.path)),
      deviceAssetId: '${asset.id}_base',
      metadata: metadata,
      group: kBackupGroup,
      isFavorite: asset.isFavorite,
      requiresWiFi: _shouldRequireWiFi(asset),
      cloudId: asset.cloudId,
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getEditUploadTask(LocalAsset asset, String stackParentId) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }
    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'stackParentId': stackParentId};
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    final metadata = UploadTaskMetadata(localAssetId: asset.id, isLivePhotos: false, livePhotoVideoId: '').toJson();

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      fields: fields,
      group: kBackupEditPairGroup,
      priority: 0,
      isFavorite: asset.isFavorite,
      requiresWiFi: _shouldRequireWiFi(asset),
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getUploadTask(LocalAsset asset, {String group = kBackupGroup, int? priority}) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      _logger.warning("Asset entity not found for ${asset.id} - ${asset.name}");
      return null;
    }

    // iOS edit pair: stack a user edit onto its original. resolveEditPair decides
    // whether to reuse a prior upload or upload the base first. Live photos skip this.
    if (!entity.isLivePhoto && CurrentPlatform.isIOS) {
      // A reverted edit flips the stack back to the original and skips the upload.
      if (asset.priorRemoteId != null && await _editRevertService.tryHandleRevert(asset)) {
        return null;
      }
      final plan = await resolveEditPair(_nativeSyncApi, asset, stackRepository: _stackRepository, log: _logger);
      switch (plan) {
        case UploadBaseFirst(:final base):
          return _buildBaseUploadTask(asset, base);
        case AbsorbIntoPrior(:final parentId):
          return getEditUploadTask(asset, parentId);
        case NoEditPair():
          break;
      }
    }

    File? file;

    /// iOS LivePhoto has two files: a photo and a video.
    /// They are uploaded separately, with video file being upload first, then returned with the assetId
    /// The assetId is then used as a metadata for the photo file upload task.
    ///
    /// We implement two separate upload groups for this, the normal one for the video file
    /// and the higher priority group for the photo file because the video file is already uploaded.
    ///
    /// The cancel operation will only cancel the video group (normal group), the photo group will not
    /// be touched, as the video file is already uploaded.

    if (entity.isLivePhoto) {
      file = await _storageRepository.getMotionFileForAsset(asset);
    } else {
      file = await _storageRepository.getFileForAsset(asset.id);
    }

    if (file == null) {
      _logger.warning("Failed to get file for asset ${asset.id} - ${asset.name}");
      return null;
    }

    String fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    final hasExtension = p.extension(fileName).isNotEmpty;
    if (!hasExtension) {
      fileName = p.setExtension(fileName, p.extension(asset.name));
    }

    final originalFileName = entity.isLivePhoto ? p.setExtension(fileName, p.extension(file.path)) : fileName;

    String metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      isLivePhotos: entity.isLivePhoto,
      livePhotoVideoId: '',
    ).toJson();

    final requiresWiFi = _shouldRequireWiFi(asset);

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      group: group,
      priority: priority,
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: entity.isLivePhoto ? null : asset.cloudId,
      adjustmentTime: entity.isLivePhoto ? null : asset.adjustmentTime?.toIso8601String(),
      latitude: entity.isLivePhoto ? null : asset.latitude?.toString(),
      longitude: entity.isLivePhoto ? null : asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getLivePhotoUploadTask(LocalAsset asset, String livePhotoVideoId) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }

    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'livePhotoVideoId': livePhotoVideoId};

    final requiresWiFi = _shouldRequireWiFi(asset);
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      fields: fields,
      group: kBackupLivePhotoGroup,
      priority: 0, // Highest priority to get upload immediately
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }

  Future<UploadTask> buildUploadTask(
    File file, {
    required String group,
    required DateTime createdAt,
    required DateTime modifiedAt,
    Map<String, String>? fields,
    String? originalFileName,
    String? deviceAssetId,
    String? metadata,
    int? priority,
    bool? isFavorite,
    bool requiresWiFi = true,
    String? cloudId,
    String? adjustmentTime,
    String? latitude,
    String? longitude,
  }) async {
    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final url = Uri.parse('$serverEndpoint/assets').toString();
    final headers = ApiService.getRequestHeaders();
    final deviceId = Store.get(StoreKey.deviceId);
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final fieldsMap = {
      'filename': originalFileName ?? filename,
      // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
      'deviceAssetId': deviceAssetId ?? '',
      'deviceId': deviceId,
      'fileCreatedAt': createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': modifiedAt.toUtc().toIso8601String(),
      'isFavorite': isFavorite?.toString() ?? 'false',
      'duration': '0',
      if (fields != null) ...fields,
      if (CurrentPlatform.isIOS && cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: cloudId,
              createdAt: createdAt.toIso8601String(),
              adjustmentTime: adjustmentTime,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        ]),
    };

    return UploadTask(
      taskId: deviceAssetId,
      displayName: originalFileName ?? filename,
      httpRequestMethod: 'POST',
      url: url,
      headers: headers,
      filename: filename,
      fields: fieldsMap,
      baseDirectory: baseDirectory,
      directory: directory,
      fileField: 'assetData',
      metaData: metadata ?? '',
      group: group,
      requiresWiFi: requiresWiFi,
      priority: priority ?? 5,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
  }
}
