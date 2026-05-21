import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../domain/service.mock.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';

void main() {
  late BackgroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockDriftLocalAssetRepository mockLocalAssetRepository;
  late MockDriftBackupRepository mockBackupRepository;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late MockNativeSyncApi mockNativeSyncApi;
  late MockEditRevertService mockEditRevertService;
  late MockDriftStackRepository mockStackRepository;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(LocalAssetStub.image1);
    registerFallbackValue(<UploadTask>[]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await SettingsRepository.ensureInitialized(db);

    await Store.put(StoreKey.serverEndpoint, 'http://test-server.com');
    await Store.put(StoreKey.deviceId, 'test-device-id');
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockLocalAssetRepository = MockDriftLocalAssetRepository();
    mockBackupRepository = MockDriftBackupRepository();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockNativeSyncApi = MockNativeSyncApi();
    mockEditRevertService = MockEditRevertService();
    mockStackRepository = MockDriftStackRepository();

    sut = BackgroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockLocalAssetRepository,
      mockBackupRepository,
      mockAssetMediaRepository,
      mockNativeSyncApi,
      mockEditRevertService,
      mockStackRepository,
    );

    // Default: no edit base, so getUploadTask falls through to the normal path.
    when(
      () => mockNativeSyncApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')),
    ).thenAnswer((_) async => null);

    // Default: not a revert, so getUploadTask proceeds with the normal flow.
    when(() => mockEditRevertService.tryHandleRevert(any())).thenAnswer((_) async => false);

    // Default: prior remotes are alive, so absorb is allowed.
    when(() => mockStackRepository.isRemoteTrashed(any())).thenAnswer((_) async => false);

    mockUploadRepository.onUploadStatus = (_) {};
    mockUploadRepository.onTaskProgress = (_) {};
  });

  tearDown(() {
    sut.dispose();
  });

  group('getUploadTask', () {
    test('should call getOriginalFilename from AssetMediaRepository for regular photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'OriginalPhoto.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.fields['filename'], equals('OriginalPhoto.jpg'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should call getOriginalFilename when original filename is null', () async {
      final asset = LocalAssetStub.image2;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => null);

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.fields['filename'], equals(asset.name));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should call getOriginalFilename for live photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(asset.id),
      ).thenAnswer((_) async => 'OriginalLivePhoto.HEIC');

      final task = await sut.getUploadTask(asset);
      expect(task, isNotNull);
      // For live photos, extension should be changed to match the video file
      expect(task!.fields['filename'], equals('OriginalLivePhoto.mov'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });
  });

  group('getUploadTask edit pair', () {
    test('absorption: stacks the edit under the prior upload via stackParentId', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final asset = LocalAssetStub.image1.copyWith(priorRemoteId: 'prior-remote-1');
      final mockEntity = MockAssetEntity();
      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/edit.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'edit.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.group, kBackupEditPairGroup);
      expect(task.fields['stackParentId'], 'prior-remote-1');
      verifyNever(() => mockNativeSyncApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('builds a base upload task for an unsynced edit', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final asset = LocalAssetStub.image1.copyWith(
        checksum: 'edited-sha1',
        adjustmentTime: DateTime(2025, 1, 1, 0, 0, 30),
      );
      final mockEntity = MockAssetEntity();
      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(
        () => mockNativeSyncApi.getBaseResource(asset.id, allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer(
        (_) async => BaseResource(path: '/tmp/base.jpg', sha1: 'original-sha1', sizeBytes: 100, mimeType: 'image/jpeg'),
      );

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.group, kBackupGroup);
      expect(task.metaData, contains('"isEditPair":true'));
    });

    test('falls through to a normal upload when base bytes match the checksum', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final asset = LocalAssetStub.image1.copyWith(
        checksum: 'same-sha1',
        adjustmentTime: DateTime(2025, 1, 1, 0, 0, 30),
      );
      final mockEntity = MockAssetEntity();
      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/file.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      when(
        () => mockNativeSyncApi.getBaseResource(asset.id, allowNetworkAccess: any(named: 'allowNetworkAccess')),
      ).thenAnswer(
        (_) async => BaseResource(path: '/tmp/base.jpg', sha1: 'same-sha1', sizeBytes: 100, mimeType: 'image/jpeg'),
      );

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.group, kBackupGroup);
      expect(task.fields.containsKey('stackParentId'), isFalse);
    });

    test('gate: skips the native read for an unedited photo (adjustmentTime == createdAt)', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final asset = LocalAssetStub.image1.copyWith(adjustmentTime: LocalAssetStub.image1.createdAt);
      final mockEntity = MockAssetEntity();
      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/file.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.group, kBackupGroup);
      expect(task.fields.containsKey('stackParentId'), isFalse);
      verifyNever(() => mockNativeSyncApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });

    test('gate: skips the native read when the photo has no adjustmentTime', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final asset = LocalAssetStub.image1; // adjustmentTime is null
      final mockEntity = MockAssetEntity();
      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/file.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.group, kBackupGroup);
      verifyNever(() => mockNativeSyncApi.getBaseResource(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
    });
  });

  group('edit pair completion', () {
    test('handleEditPair: enqueues the edit stacked onto the uploaded base', () async {
      final asset = LocalAssetStub.image1;
      final metadata = UploadTaskMetadata(
        localAssetId: asset.id,
        isLivePhotos: false,
        livePhotoVideoId: '',
        isEditPair: true,
      );
      final update = TaskStatusUpdate(
        UploadTask(url: 'http://test-server.com', filename: 'base.jpg'),
        TaskStatus.complete,
        null,
        '{"id":"base-remote-1"}',
      );
      final mockEntity = MockAssetEntity();
      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockLocalAssetRepository.getById(asset.id)).thenAnswer((_) async => asset);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => File('/path/to/edit.jpg'));
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'edit.jpg');
      when(() => mockUploadRepository.enqueueBackgroundAll(any())).thenAnswer((_) async => [true]);

      await sut.handleEditPair(update, metadata);

      final enqueued =
          verify(() => mockUploadRepository.enqueueBackgroundAll(captureAny())).captured.single as List<UploadTask>;
      expect(enqueued.single.fields['stackParentId'], 'base-remote-1');
      expect(enqueued.single.group, kBackupEditPairGroup);
    });

    test('handleEditPair: does nothing for a non edit-pair upload', () async {
      const metadata = UploadTaskMetadata(localAssetId: 'local-1', isLivePhotos: false, livePhotoVideoId: '');
      final update = TaskStatusUpdate(
        UploadTask(url: 'http://test-server.com', filename: 'photo.jpg'),
        TaskStatus.complete,
        null,
        '{"id":"remote-1"}',
      );

      await sut.handleEditPair(update, metadata);

      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('recordPriorRemoteIdOnSuccess: marks the local synced with the uploaded id', () async {
      final asset = LocalAssetStub.image1;
      final metadata = UploadTaskMetadata(localAssetId: asset.id, isLivePhotos: false, livePhotoVideoId: '');
      final update = TaskStatusUpdate(
        UploadTask(url: 'http://test-server.com', filename: 'photo.jpg'),
        TaskStatus.complete,
        null,
        '{"id":"remote-1"}',
      );
      when(() => mockLocalAssetRepository.getById(asset.id)).thenAnswer((_) async => asset);
      when(
        () => mockLocalAssetRepository.markSynced(
          any(),
          priorRemoteId: any(named: 'priorRemoteId'),
          syncedChecksum: any(named: 'syncedChecksum'),
        ),
      ).thenAnswer((_) async {});

      await sut.recordPriorRemoteIdOnSuccess(update, metadata);

      verify(
        () => mockLocalAssetRepository.markSynced(
          asset.id,
          priorRemoteId: 'remote-1',
          syncedChecksum: asset.checksum,
        ),
      ).called(1);
    });

    test('recordPriorRemoteIdOnSuccess: skips edit-pair base uploads', () async {
      const metadata = UploadTaskMetadata(
        localAssetId: 'local-1',
        isLivePhotos: false,
        livePhotoVideoId: '',
        isEditPair: true,
      );
      final update = TaskStatusUpdate(
        UploadTask(url: 'http://test-server.com', filename: 'base.jpg'),
        TaskStatus.complete,
        null,
        '{"id":"base-remote-1"}',
      );

      await sut.recordPriorRemoteIdOnSuccess(update, metadata);

      verifyNever(
        () => mockLocalAssetRepository.markSynced(
          any(),
          priorRemoteId: any(named: 'priorRemoteId'),
          syncedChecksum: any(named: 'syncedChecksum'),
        ),
      );
    });

    test('recordPriorRemoteIdOnSuccess: skips live photos', () async {
      const metadata = UploadTaskMetadata(localAssetId: 'local-1', isLivePhotos: true, livePhotoVideoId: '');
      final update = TaskStatusUpdate(
        UploadTask(url: 'http://test-server.com', filename: 'live.mov'),
        TaskStatus.complete,
        null,
        '{"id":"video-remote-1"}',
      );

      await sut.recordPriorRemoteIdOnSuccess(update, metadata);

      verifyNever(
        () => mockLocalAssetRepository.markSynced(
          any(),
          priorRemoteId: any(named: 'priorRemoteId'),
          syncedChecksum: any(named: 'syncedChecksum'),
        ),
      );
    });
  });

  group('getLivePhotoUploadTask', () {
    test('should call getOriginalFilename for live photo upload task', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/livephoto.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(asset.id),
      ).thenAnswer((_) async => 'OriginalLivePhoto.HEIC');

      final task = await sut.getLivePhotoUploadTask(asset, 'video-id-123');

      expect(task, isNotNull);
      expect(task!.fields['filename'], equals('OriginalLivePhoto.HEIC'));
      expect(task.fields['livePhotoVideoId'], equals('video-id-123'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should call getOriginalFilename when original filename is null', () async {
      final asset = LocalAssetStub.image2;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/fallback.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => null);

      final task = await sut.getLivePhotoUploadTask(asset, 'video-id-456');
      expect(task, isNotNull);
      // Should fall back to asset.name when original filename is null
      expect(task!.fields['filename'], equals(asset.name));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });
  });

  group('Server Info - cloudId and eTag metadata', () {
    test('should include cloudId and eTag metadata on iOS when server version is 2.4+', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutWithV24 = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAssetMediaRepository,
        mockNativeSyncApi,
        mockEditRevertService,
        mockStackRepository,
      );
      addTearDown(() => sutWithV24.dispose());

      final assetWithCloudId = LocalAsset(
        id: 'test-asset-id',
        name: 'test.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: 'cloud-id-123',
        latitude: 37.7749,
        longitude: -122.4194,
        adjustmentTime: DateTime(2026, 1, 2),
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithCloudId.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(assetWithCloudId.id)).thenAnswer((_) async => 'test.jpg');

      final task = await sutWithV24.getUploadTask(assetWithCloudId);

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isTrue);

      final metadata = jsonDecode(task.fields['metadata']!) as List;
      expect(metadata, hasLength(1));
      expect(metadata[0]['key'], equals('mobile-app'));
      expect(metadata[0]['value']['iCloudId'], equals('cloud-id-123'));
      expect(metadata[0]['value']['createdAt'], isNotNull);
      expect(metadata[0]['value']['adjustmentTime'], isNotNull);
      expect(metadata[0]['value']['latitude'], isNotNull);
      expect(metadata[0]['value']['longitude'], isNotNull);
    });

    test('should NOT include metadata on Android regardless of server version', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutAndroid = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAssetMediaRepository,
        mockNativeSyncApi,
        mockEditRevertService,
        mockStackRepository,
      );
      addTearDown(() => sutAndroid.dispose());

      final assetWithCloudId = LocalAsset(
        id: 'test-asset-id',
        name: 'test.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: 'cloud-id-123',
        latitude: 37.7749,
        longitude: -122.4194,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithCloudId.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(assetWithCloudId.id)).thenAnswer((_) async => 'test.jpg');

      final task = await sutAndroid.getUploadTask(assetWithCloudId);

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isFalse);
    });

    test('should NOT include metadata when cloudId is null even on iOS with server 2.4+', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutWithV24 = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAssetMediaRepository,
        mockNativeSyncApi,
        mockEditRevertService,
        mockStackRepository,
      );
      addTearDown(() => sutWithV24.dispose());

      final assetWithoutCloudId = LocalAsset(
        id: 'test-asset-id',
        name: 'test.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: null, // No cloudId
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithoutCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithoutCloudId.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(assetWithoutCloudId.id),
      ).thenAnswer((_) async => 'test.jpg');

      final task = await sutWithV24.getUploadTask(assetWithoutCloudId);

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isFalse);
    });

    test('should include metadata for live photos with cloudId on iOS 2.4+', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutWithV24 = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAssetMediaRepository,
        mockNativeSyncApi,
        mockEditRevertService,
        mockStackRepository,
      );
      addTearDown(() => sutWithV24.dispose());

      final assetWithCloudId = LocalAsset(
        id: 'test-livephoto-id',
        name: 'livephoto.heic',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: 'cloud-id-livephoto',
        latitude: 37.7749,
        longitude: -122.4194,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/livephoto.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithCloudId.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(assetWithCloudId.id),
      ).thenAnswer((_) async => 'livephoto.heic');

      final task = await sutWithV24.getLivePhotoUploadTask(assetWithCloudId, 'video-123');

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isTrue);
      expect(task.fields['livePhotoVideoId'], equals('video-123'));

      final metadata = jsonDecode(task.fields['metadata']!) as List;
      expect(metadata, hasLength(1));
      expect(metadata[0]['key'], equals('mobile-app'));
      expect(metadata[0]['value']['iCloudId'], equals('cloud-id-livephoto'));
    });
  });
}
