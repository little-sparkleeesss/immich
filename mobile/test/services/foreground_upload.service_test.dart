import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../api.mocks.dart';
import '../domain/service.mock.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';

void main() {
  late ForegroundUploadService sut;
  late MockUploadRepository mockUpload;
  late MockStorageRepository mockStorage;
  late MockDriftBackupRepository mockBackup;
  late MockConnectivityApi mockConnectivity;
  late MockAssetMediaRepository mockAssetMedia;
  late MockNativeSyncApi mockNativeApi;
  late MockDriftLocalAssetRepository mockLocalAsset;
  late MockEditRevertService mockEditRevert;
  late MockDriftStackRepository mockStack;
  late Drift db;
  late Directory tmp;

  final edited = LocalAsset(
    id: 'edited-1',
    name: 'edited-1.jpg',
    type: AssetType.image,
    createdAt: DateTime(2025, 1, 1, 12),
    updatedAt: DateTime(2025, 1, 1, 12),
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: false,
    checksum: 'edited-sha1',
    // 30s past createdAt → the edit gate fires.
    adjustmentTime: DateTime(2025, 1, 1, 12, 0, 30),
  );

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(edited);
    registerFallbackValue(File('/tmp/fallback'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await SettingsRepository.ensureInitialized(db);
    await Store.put(StoreKey.serverEndpoint, 'http://test-server.com');
    await Store.put(StoreKey.deviceId, 'test-device-id');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
  });

  setUp(() async {
    mockUpload = MockUploadRepository();
    mockStorage = MockStorageRepository();
    mockBackup = MockDriftBackupRepository();
    mockConnectivity = MockConnectivityApi();
    mockAssetMedia = MockAssetMediaRepository();
    mockNativeApi = MockNativeSyncApi();
    mockLocalAsset = MockDriftLocalAssetRepository();
    mockEditRevert = MockEditRevertService();
    mockStack = MockDriftStackRepository();

    sut = ForegroundUploadService(
      mockUpload,
      mockStorage,
      mockBackup,
      mockConnectivity,
      mockAssetMedia,
      mockNativeApi,
      mockLocalAsset,
      mockEditRevert,
      mockStack,
    );

    tmp = await Directory.systemTemp.createTemp('fg_upload_test');
    final assetFile = File('${tmp.path}/edited-1.jpg')..writeAsStringSync('edit-bytes');
    final baseFile = File('${tmp.path}/edited-1_base.jpg')..writeAsStringSync('base-bytes');

    when(() => mockStorage.clearCache()).thenAnswer((_) async {});
    when(() => mockConnectivity.getCapabilities()).thenAnswer((_) async => [NetworkCapability.unmetered]);

    final entity = MockAssetEntity();
    when(() => entity.isLivePhoto).thenReturn(false);
    when(() => mockStorage.getAssetEntityForAsset(any())).thenAnswer((_) async => entity);
    when(() => mockStorage.isAssetAvailableLocally(any())).thenAnswer((_) async => true);
    when(() => mockStorage.getFileForAsset(any())).thenAnswer((_) async => assetFile);
    when(() => mockAssetMedia.getOriginalFilename(any())).thenAnswer((_) async => 'edited-1.jpg');

    // Not a revert; prior is alive; the edit gate fires with a real base file.
    when(() => mockEditRevert.tryHandleRevert(any())).thenAnswer((_) async => false);
    when(() => mockStack.isRemoteTrashed(any())).thenAnswer((_) async => false);
    when(() => mockNativeApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess'))).thenAnswer(
      (_) async => BaseResource(path: baseFile.path, sha1: 'base-sha1', sizeBytes: 10, mimeType: 'image/jpeg'),
    );
    when(
      () => mockLocalAsset.markSynced(
        any(),
        priorRemoteId: any(named: 'priorRemoteId'),
        syncedChecksum: any(named: 'syncedChecksum'),
      ),
    ).thenAnswer((_) async {});
  });

  tearDown(() async {
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
  });

  group('edit pair base failure', () {
    test('does not upload the edit or mark synced when the base upload fails', () async {
      // Base upload fails; the edit upload should never run.
      when(
        () => mockUpload.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
        ),
      ).thenAnswer((_) async => UploadResult.error(errorMessage: 'boom', statusCode: 500));

      await sut.uploadManual([edited]);

      // Exactly one upload attempt (the base). The edit must not be uploaded,
      // and the asset must stay a candidate (no markSynced).
      verify(
        () => mockUpload.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: 'baseResource[edited-1]',
        ),
      ).called(1);
      verifyNever(
        () => mockUpload.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: 'asset[edited-1]',
        ),
      );
      verifyNever(
        () => mockLocalAsset.markSynced(
          any(),
          priorRemoteId: any(named: 'priorRemoteId'),
          syncedChecksum: any(named: 'syncedChecksum'),
        ),
      );
    });

    test('uploads the edit with stackParentId and marks synced when the base succeeds', () async {
      var uploadCount = 0;
      when(
        () => mockUpload.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
        ),
      ).thenAnswer((invocation) async {
        uploadCount++;
        // base first → base-remote, then the edit → edit-remote.
        return UploadResult.success(remoteAssetId: uploadCount == 1 ? 'base-remote' : 'edit-remote');
      });

      await sut.uploadManual([edited]);

      // The edit upload carries the base's id as stackParentId.
      final captured = verify(
        () => mockUpload.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: captureAny(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: 'asset[edited-1]',
        ),
      ).captured.single as Map<String, String>;
      expect(captured['stackParentId'], 'base-remote');

      verify(
        () => mockLocalAsset.markSynced(
          'edited-1',
          priorRemoteId: 'edit-remote',
          syncedChecksum: 'edited-sha1',
        ),
      ).called(1);
    });
  });
}
