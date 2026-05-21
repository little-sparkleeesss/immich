import Photos
import CryptoKit
import UniformTypeIdentifiers

struct AssetWrapper: Hashable, Equatable {
  let asset: PlatformAsset

  init(with asset: PlatformAsset) {
    self.asset = asset
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(self.asset.id)
  }

  static func == (lhs: AssetWrapper, rhs: AssetWrapper) -> Bool {
    return lhs.asset.id == rhs.asset.id
  }
}

class NativeSyncApiImpl: ImmichPlugin, NativeSyncApi, FlutterPlugin {
  static let name = "NativeSyncApi"
  
  static func register(with registrar: any FlutterPluginRegistrar) {
    let instance = NativeSyncApiImpl()
    NativeSyncApiSetup.setUp(binaryMessenger: registrar.messenger(), api: instance)
    registrar.publish(instance)
  }
  
  func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
    super.detachFromEngine()
  }
  
  private let defaults: UserDefaults
  private let changeTokenKey = "immich:changeToken"
  private let albumTypes: [PHAssetCollectionType] = [.album, .smartAlbum]
  private let recoveredAlbumSubType = 1000000219
  
  private var hashTask: Task<Void?, Error>?
  private static let hashCancelledCode = "HASH_CANCELLED"
  private static let hashCancelled = Result<[HashResult], Error>.failure(PigeonError(code: hashCancelledCode, message: "Hashing cancelled", details: nil))
  
  
  init(with defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }
  
  @available(iOS 16, *)
  private func getChangeToken() -> PHPersistentChangeToken? {
    guard let data = defaults.data(forKey: changeTokenKey) else {
      return nil
    }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data)
  }
  
  @available(iOS 16, *)
  private func saveChangeToken(token: PHPersistentChangeToken) -> Void {
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
      return
    }
    defaults.set(data, forKey: changeTokenKey)
  }
  
  func clearSyncCheckpoint() -> Void {
    defaults.removeObject(forKey: changeTokenKey)
  }
  
  func checkpointSync() {
    guard #available(iOS 16, *) else {
      return
    }
    saveChangeToken(token: PHPhotoLibrary.shared().currentChangeToken)
  }
  
  func shouldFullSync() -> Bool {
    guard #available(iOS 16, *),
          PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
          let storedToken = getChangeToken() else {
      // When we do not have access to photo library, older iOS version or No token available, fallback to full sync
      return true
    }
    
    guard let _ = try? PHPhotoLibrary.shared().fetchPersistentChanges(since: storedToken) else {
      // Cannot fetch persistent changes
      return true
    }
    
    return false
  }
  
  func getAlbums() throws -> [PlatformAlbum] {
    var albums: [PlatformAlbum] = []
    
    albumTypes.forEach { type in
      let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
      for i in 0..<collections.count {
        let album = collections.object(at: i)
        
        // Ignore recovered album
        if(album.assetCollectionSubtype.rawValue == self.recoveredAlbumSubType) {
          continue;
        }
        
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        options.includeHiddenAssets = false
        
        let assets = getAssetsFromAlbum(in: album, options: options)
        
        let isCloud = album.assetCollectionSubtype == .albumCloudShared || album.assetCollectionSubtype == .albumMyPhotoStream
        
        var domainAlbum = PlatformAlbum(
          id: album.localIdentifier,
          name: album.localizedTitle ?? album.localIdentifier,
          updatedAt: nil,
          isCloud: isCloud,
          assetCount: Int64(assets.count)
        )
        
        if let firstAsset = assets.firstObject {
          domainAlbum.updatedAt = firstAsset.modificationDate.map { Int64($0.timeIntervalSince1970) }
        }
        
        albums.append(domainAlbum)
      }
    }
    return albums.sorted { $0.id < $1.id }
  }
  
  func getMediaChanges() throws -> SyncDelta {
    guard #available(iOS 16, *) else {
      throw PigeonError(code: "UNSUPPORTED_OS", message: "This feature requires iOS 16 or later.", details: nil)
    }
    
    guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
      throw PigeonError(code: "NO_AUTH", message: "No photo library access", details: nil)
    }
    
    guard let storedToken = getChangeToken() else {
      // No token exists, definitely need a full sync
      print("MediaManager::getMediaChanges: No token found")
      throw PigeonError(code: "NO_TOKEN", message: "No stored change token", details: nil)
    }
    
    let currentToken = PHPhotoLibrary.shared().currentChangeToken
    if storedToken == currentToken {
      return SyncDelta(hasChanges: false, updates: [], deletes: [], assetAlbums: [:])
    }
    
    do {
      let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: storedToken)
      
      var updatedAssets: Set<AssetWrapper> = []
      var deletedAssets: Set<String> = []
      
      for change in changes {
        guard let details = try? change.changeDetails(for: PHObjectType.asset) else { continue }
        
        let updated = details.updatedLocalIdentifiers.union(details.insertedLocalIdentifiers)
        deletedAssets.formUnion(details.deletedLocalIdentifiers)
        
        if (updated.isEmpty) { continue }
        
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(updated), options: options)
        for i in 0..<result.count {
          let asset = result.object(at: i)
          
          // Asset wrapper only uses the id for comparison. Multiple change can contain the same asset, skip duplicate changes
          let predicate = PlatformAsset(
            id: asset.localIdentifier,
            name: "",
            type: 0,
            durationMs: 0,
            orientation: 0,
            isFavorite: false,
            playbackStyle: .unknown
          )
          if (updatedAssets.contains(AssetWrapper(with: predicate))) {
            continue
          }
          
          let domainAsset = AssetWrapper(with: asset.toPlatformAsset())
          updatedAssets.insert(domainAsset)
        }
      }
      
      let updates = Array(updatedAssets.map { $0.asset })
      return SyncDelta(hasChanges: true, updates: updates, deletes: Array(deletedAssets), assetAlbums: buildAssetAlbumsMap(assets: updates))
    }
  }
  
  
  private func buildAssetAlbumsMap(assets: Array<PlatformAsset>) -> [String: [String]] {
    guard !assets.isEmpty else {
      return [:]
    }
    
    var albumAssets: [String: [String]] = [:]
    
    for type in albumTypes {
      let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
      collections.enumerateObjects { (album, _, _) in
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier IN %@", assets.map(\.id))
        options.includeHiddenAssets = false
        let result = self.getAssetsFromAlbum(in: album, options: options)
        result.enumerateObjects { (asset, _, _) in
          albumAssets[asset.localIdentifier, default: []].append(album.localIdentifier)
        }
      }
    }
    return albumAssets
  }
  
  func getAssetIdsForAlbum(albumId: String) throws -> [String] {
    let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
    guard let album = collections.firstObject else {
      return []
    }
    
    var ids: [String] = []
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    let assets = getAssetsFromAlbum(in: album, options: options)
    assets.enumerateObjects { (asset, _, _) in
      ids.append(asset.localIdentifier)
    }
    return ids
  }
  
  func getAssetsCountSince(albumId: String, timestamp: Int64) throws -> Int64 {
    let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
    guard let album = collections.firstObject else {
      return 0
    }
    
    let date = NSDate(timeIntervalSince1970: TimeInterval(timestamp))
    let options = PHFetchOptions()
    options.predicate = NSPredicate(format: "creationDate > %@ OR modificationDate > %@", date, date)
    options.includeHiddenAssets = false
    let assets = getAssetsFromAlbum(in: album, options: options)
    return Int64(assets.count)
  }
  
  func getAssetsForAlbum(albumId: String, updatedTimeCond: Int64?) throws -> [PlatformAsset] {
    let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
    guard let album = collections.firstObject else {
      return []
    }
    
    let options = PHFetchOptions()
    options.includeHiddenAssets = false
    if(updatedTimeCond != nil) {
      let date = NSDate(timeIntervalSince1970: TimeInterval(updatedTimeCond!))
      options.predicate = NSPredicate(format: "creationDate > %@ OR modificationDate > %@", date, date)
    }
    
    let result = getAssetsFromAlbum(in: album, options: options)
    if(result.count == 0) {
      return []
    }
    
    var assets: [PlatformAsset] = []
    result.enumerateObjects { (asset, _, _) in
      assets.append(asset.toPlatformAsset())
    }
    return assets
  }
  
  func hashAssets(assetIds: [String], allowNetworkAccess: Bool, completion: @escaping (Result<[HashResult], Error>) -> Void) {
    if let prevTask = hashTask {
      prevTask.cancel()
      hashTask = nil
    }
    hashTask = Task { [weak self] in
      var missingAssetIds = Set(assetIds)
      var assets = [PHAsset]()
      assets.reserveCapacity(assetIds.count)
      PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil).enumerateObjects { (asset, _, stop) in
        if Task.isCancelled {
          stop.pointee = true
          return
        }
        missingAssetIds.remove(asset.localIdentifier)
        assets.append(asset)
      }
      
      if Task.isCancelled {
        return self?.completeWhenActive(for: completion, with: Self.hashCancelled)
      }
      
      await withTaskGroup(of: HashResult?.self) { taskGroup in
        var results = [HashResult]()
        results.reserveCapacity(assets.count)
        for asset in assets {
          if Task.isCancelled {
            return self?.completeWhenActive(for: completion, with: Self.hashCancelled)
          }
          taskGroup.addTask {
            guard let self = self else { return nil }
            return await self.hashAsset(asset, allowNetworkAccess: allowNetworkAccess)
          }
        }
        
        for await result in taskGroup {
          guard let result = result else {
            return self?.completeWhenActive(for: completion, with: Self.hashCancelled)
          }
          results.append(result)
        }
        
        for missing in missingAssetIds {
          results.append(HashResult(assetId: missing, error: "Asset not found in library", hash: nil))
        }
        
        return self?.completeWhenActive(for: completion, with: .success(results))
      }
    }
  }
  
  func cancelHashing() {
    hashTask?.cancel()
    hashTask = nil
  }
  
  private func hashAsset(_ asset: PHAsset, allowNetworkAccess: Bool) async -> HashResult? {
    class RequestRef {
      var id: PHAssetResourceDataRequestID?
    }
    let requestRef = RequestRef()
    return await withTaskCancellationHandler(operation: {
      if Task.isCancelled {
        return nil
      }
      
      guard let resource = asset.getResource() else {
        return HashResult(assetId: asset.localIdentifier, error: "Cannot get asset resource", hash: nil)
      }
      
      if Task.isCancelled {
        return nil
      }
      
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = allowNetworkAccess
      
      return await withCheckedContinuation { continuation in
        var hasher = Insecure.SHA1()
        
        requestRef.id = PHAssetResourceManager.default().requestData(
          for: resource,
          options: options,
          dataReceivedHandler: { data in
            hasher.update(data: data)
          },
          completionHandler: { error in
            let result: HashResult? = switch (error) {
            case let e as PHPhotosError where e.code == .userCancelled: nil
            case let .some(e): HashResult(
              assetId: asset.localIdentifier,
              error: "Failed to hash asset: \(e.localizedDescription)",
              hash: nil
            )
            case .none:
              HashResult(
                assetId: asset.localIdentifier,
                error: nil,
                hash: Data(hasher.finalize()).base64EncodedString()
              )
            }
            continuation.resume(returning: result)
          }
        )
      }
    }, onCancel: {
      guard let requestId = requestRef.id else { return }
      PHAssetResourceManager.default().cancelDataRequest(requestId)
    })
  }
  
  func getTrashedAssets() throws -> [String: [PlatformAsset]] {
    throw PigeonError(code: "UNSUPPORTED_OS", message: "This feature not supported on iOS.", details: nil)
  }

  func restoreFromTrashById(mediaId: String, type: Int64, completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(false))
  }
  
  private func getAssetsFromAlbum(in album: PHAssetCollection, options: PHFetchOptions) -> PHFetchResult<PHAsset> {
    // Ensure to actually getting all assets for the Recents album
    if (album.assetCollectionSubtype == .smartAlbumUserLibrary) {
      return PHAsset.fetchAssets(with: options)
    } else {
      return PHAsset.fetchAssets(in: album, options: options)
    }
  }
  
  func getCloudIdForAssetIds(assetIds: [String]) throws -> [CloudIdResult] {
    guard #available(iOS 16, *) else {
      return assetIds.map { CloudIdResult(assetId: $0) }
    }
    
    var mappings: [CloudIdResult] = []
    let result = PHPhotoLibrary.shared().cloudIdentifierMappings(forLocalIdentifiers: assetIds)
    for (key, value) in result {
      switch value {
      case .success(let cloudIdentifier):
        let cloudId = cloudIdentifier.stringValue
        // Ignores invalid cloud ids of the format "GUID:ID:". Valid Ids are of the form "GUID:ID:HASH"
        if !cloudId.hasSuffix(":") {
          mappings.append(CloudIdResult(assetId: key, cloudId: cloudId))
        } else {
          mappings.append(CloudIdResult(assetId: key, error: "Incomplete Cloud Id: \(cloudId)"))
        }
      case .failure(let error):
        mappings.append(CloudIdResult(assetId: key, error: "Error getting Cloud Id: \(error.localizedDescription)"))
      }
    }
    return mappings;
  }

  func getBaseResource(
    assetId: String,
    allowNetworkAccess: Bool,
    completion: @escaping (Result<BaseResource?, Error>) -> Void
  ) {
    Task { [weak self] in
      guard let self = self else { return }

      guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
        return self.completeWhenActive(for: completion, with: .success(nil))
      }

      let resources = PHAssetResource.assetResources(for: asset)
      let state = await Self.classifyEdit(resources: resources, allowNetworkAccess: allowNetworkAccess)
      guard state == .edited, let original = resources.first(where: { $0.type == .photo }) else {
        return self.completeWhenActive(for: completion, with: .success(nil))
      }

      do {
        let result = try await self.streamBaseResource(
          resource: original,
          localId: asset.localIdentifier,
          allowNetworkAccess: allowNetworkAccess
        )
        self.completeWhenActive(for: completion, with: .success(result))
      } catch {
        self.completeWhenActive(for: completion, with: .failure(error))
      }
    }
  }

  // Returns whether the asset carries a live Photos edit without reading the photo
  // itself, only the small adjustment metadata. The revert probe relies on this to
  // tell "not edited" apart from "couldn't read" (offloaded to iCloud), so it never
  // mistakes an unreadable edit for a revert.
  func getEditState(
    assetId: String,
    allowNetworkAccess: Bool,
    completion: @escaping (Result<EditState, Error>) -> Void
  ) {
    Task { [weak self] in
      guard let self = self else { return }
      guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject else {
        // Not in the library, so don't answer "not edited" (the caller acts on that).
        return self.completeWhenActive(for: completion, with: .success(.unknown))
      }
      let state = await Self.classifyEdit(
        resources: PHAssetResource.assetResources(for: asset),
        allowNetworkAccess: allowNetworkAccess
      )
      self.completeWhenActive(for: completion, with: .success(state))
    }
  }

  // adjustmentRenderTypes for a photo with no real edit: a plain capture, a
  // Photographic Style, or a reverted edit. A real edit changes this value.
  private static let kNoEditRenderTypes = 27648

  // Works out the edit state from Adjustments.plist only (never reads the photo).
  // adjustmentRenderTypes is the signal: a real edit moves it off the baseline, while a
  // plain capture, a Photographic Style, and a reverted edit all sit at the baseline. The
  // editor id is NOT reliable: com.apple.camera authors both styles and some real edits
  // (e.g. changing the Photographic Style after capture), so we key off the render types
  // alone. Cleanup and object-removal write AdjustmentsSecondary.data, which we count as
  // edited. unknown = couldn't read the plist (offloaded, no network).
  private static func classifyEdit(resources: [PHAssetResource], allowNetworkAccess: Bool) async -> EditState {
    if resources.contains(where: { $0.originalFilename == "AdjustmentsSecondary.data" }) {
      return .edited
    }
    guard let adjRes = resources.first(where: { $0.originalFilename == "Adjustments.plist" }) else {
      return .notEdited
    }
    guard let buf = await collectResourceData(adjRes, allowNetworkAccess: allowNetworkAccess),
      let plist = try? PropertyListSerialization.propertyList(from: buf, options: [], format: nil) as? [String: Any]
    else {
      return .unknown
    }
    let renderTypes = (plist["adjustmentRenderTypes"] as? NSNumber)?.intValue
    let isUserEdit = renderTypes != nil && renderTypes != kNoEditRenderTypes
    return isUserEdit ? .edited : .notEdited
  }

  private func streamBaseResource(
    resource: PHAssetResource,
    localId: String,
    allowNetworkAccess: Bool
  ) async throws -> BaseResource {
    let safeId = localId.replacingOccurrences(of: "/", with: "_")
    let suffix = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "bin"
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("immich_base", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let unique = UUID().uuidString.prefix(8)
    let tempUrl = tempDir.appendingPathComponent("\(safeId)_\(unique)_base.\(suffix)")

    // Write the resource to disk and hash it chunk by chunk, so a big original (e.g.
    // ProRAW) never sits fully in memory on the upload thread.
    FileManager.default.createFile(atPath: tempUrl.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: tempUrl) else {
      throw NSError(
        domain: "NativeSyncApi",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to open temp file for base resource \(localId)"]
      )
    }

    var hasher = Insecure.SHA1()
    var totalBytes: Int64 = 0
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = allowNetworkAccess

    let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      var writeFailed = false
      PHAssetResourceManager.default().requestData(
        for: resource,
        options: options,
        dataReceivedHandler: { chunk in
          if writeFailed { return }
          do {
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            totalBytes += Int64(chunk.count)
          } catch {
            writeFailed = true
          }
        },
        completionHandler: { error in continuation.resume(returning: error == nil && !writeFailed) }
      )
    }

    try? handle.close()

    guard succeeded else {
      try? FileManager.default.removeItem(at: tempUrl)
      throw NSError(
        domain: "NativeSyncApi",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Failed to read base resource for \(localId)"]
      )
    }

    let sha1 = Data(hasher.finalize()).base64EncodedString()
    let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? "application/octet-stream"
    return BaseResource(path: tempUrl.path, sha1: sha1, sizeBytes: totalBytes, mimeType: mime)
  }

  private static func collectResourceData(
    _ resource: PHAssetResource,
    allowNetworkAccess: Bool
  ) async -> Data? {
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = allowNetworkAccess
    var buffer = Data()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
      PHAssetResourceManager.default().requestData(
        for: resource,
        options: options,
        dataReceivedHandler: { data in buffer.append(data) },
        completionHandler: { error in continuation.resume(returning: error == nil ? buffer : nil) }
      )
    }
  }

}
