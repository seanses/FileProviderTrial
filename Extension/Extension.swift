/*
See LICENSE folder for this sample’s licensing information.

Abstract:
The main entry point for the file-syncing extension.
*/

import FileProvider
import Common
import CoreServices
import QuickLookThumbnailing
import UniformTypeIdentifiers
import os.log
import PushKit


public class Extension: NSObject, NSFileProviderReplicatedExtension {
    let logger = Logger(subsystem: "com.example.apple-samplecode.FruitBasket", category: "extension")

    @objc(_initializedByViewServices)
    static let _initializedByViewServices = true

    var connection: DomainConnection {
        DomainConnection(domain, secret: UserDefaults.sharedContainerDefaults.secret(for: domain.identifier), hostname: hostname, port: port)
    }
    let port: in_port_t
    let hostname: String
    let queue = DispatchQueue(label: "completion queue")
    let fetchChunkQueue = DispatchQueue(label: "fetch chunks queue", attributes: [.concurrent])
    let domain: NSFileProviderDomain
    var manager: NSFileProviderManager
    var observedDefaults: UserDefaults
    var observation: NSKeyValueObservation?
    
    required public init(domain: NSFileProviderDomain) {
        self.domain = domain
        port = domain.identifier.port ?? defaultPort
        hostname = UserDefaults.sharedContainerDefaults.hostname
        manager = NSFileProviderManager(for: domain)!

        observedDefaults = UserDefaults.sharedContainerDefaults

        do {
            temporaryDirectoryURL = try manager.temporaryDirectoryURL()
        } catch {
            fatalError("failed to get temporary directory: \(error)")
        }
        super.init()

        observation = observedDefaults.observe(\.blockedProcesses, options: [.initial, .new]) { _, change in
            UserDefaults().setValue(change.newValue ?? [], forKey: "NSFileProviderExtensionNonMaterializingProcessNames")
        }
        
        logger.debug("Extension init")
    }

    public func invalidate() {
        
    }

    public func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
                     completionHandler completionHander: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        logger.debug("🧩 item(forIdentifier:\(identifier.rawValue, privacy: .public)) @ domainVersion(\(request.domainVersion?.description ?? "<nil>", privacy: .public))")

        if identifier == .trashContainer {
            if UserDefaults.sharedContainerDefaults.trashDisabled {
                logger.debug("🌀 trashing disabled: returning noSuchItem error")
                let error = NSFileProviderError(.noSuchItem)
                completionHander(nil, error)
                return Progress()
            }
        }

        let progress = connection.makeJSONCall(DomainService.FetchItemParameter(itemIdentifier: DomainService.ItemIdentifier(identifier))) { result in
            switch result {
            case .failure(let error):
                completionHander(nil, error.toPresentableError())
            case .success(let response):
                completionHander(Item(response.item), nil)
            }
        }
        progress.cancellationHandler = { completionHander(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        return progress
    }
    
    let temporaryDirectoryURL: URL
    
    func makeTemporaryURL(_ purpose: String, _ ext: String? = nil) -> URL {
        if let ext = ext {
            return temporaryDirectoryURL.appendingPathComponent("\(purpose)-\(UUID().uuidString).\(ext)")
        } else {
            return temporaryDirectoryURL.appendingPathComponent("\(purpose)-\(UUID().uuidString)")
        }
    }
}

extension Extension {
    func fetchResourceFork(sourceItem: Item, url: URL?, item: NSFileProviderItem?, error: Error?,
                           completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress? {
        if let error = error {
            completionHandler(url, item, error)
            return nil
        }

        guard let url = url else {
            completionHandler(nil, nil, CommonError.internalError.toPresentableError())
            return nil
        }

        let forkParam = DomainService.DownloadItemParameter(itemIdentifier: sourceItem.entry.id, requestedRevision: sourceItem.entry.revision,
                                                            resourceFork: true)
        let forkProgress = self.connection.makeJSONCallWithReturn(forkParam) { result in
            switch result {
            case .failure(let error):
                completionHandler(nil, nil, error.toPresentableError())
            case .success((_, let fork)):
                do {
                    let forkURL = url.appendingPathComponent("..namedfork/rsrc")
                    try fork.write(to: forkURL)
                    completionHandler(url, item, nil)
                } catch let error {
                    completionHandler(nil, nil, error.toPresentableError())
                }
            }
        }

        return forkProgress
    }

    private func adjustRequestedRange(requestedRange: NSRange, alignment: Int, fileSize: Int) -> NSRange {
        guard fileSize != 0, requestedRange.location >= 0, requestedRange.length > 0 else {
            return NSRange(location: 0, length: -1)
        }

        var extent: NSRange
        let alignedStart = requestedRange.location & ~(alignment - 1)
        let length = requestedRange.location + requestedRange.length - alignedStart
        var alignedLength = ((length + alignment - 1) & ~(alignment - 1))
        if alignedLength < UserDefaults.sharedContainerDefaults.BRMChunkSize {
            alignedLength = UserDefaults.sharedContainerDefaults.BRMChunkSize
        }

        let alignedEnd = alignedStart + alignedLength

        if fileSize <= UserDefaults.sharedContainerDefaults.minSizeFileForBRM {
            //Materialize the entire file.
            extent = NSRange(location: 0, length: -1)
        } else if fileSize > alignedStart && fileSize >= alignedEnd {
            extent = NSRange(location: alignedStart, length: alignedLength)
            if UserDefaults.sharedContainerDefaults.isUnalignedBRMResponse {
                extent.location += 5
                extent.length -= 5
            }
        } else if fileSize > alignedStart && fileSize < alignedEnd {
            //Trim the end of the file.
            extent = NSRange(location: alignedStart, length: fileSize - alignedStart)
        } else {
            //Materialize the entire file.
            extent = NSRange(location: 0, length: -1)
        }

        return extent
    }

    private func fetchContentsInternal(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        range: NSRange?,
        request: NSFileProviderRequest,
        alignment: Int,
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange?,
                                      Error?) -> Void) -> Progress {

        let progress = Progress(totalUnitCount: 110)

        let itemProgress = self.item(for: itemIdentifier, request: request) { itemOptional, errorOptional in
            if let error = errorOptional as NSError? {
                self.logger.error("Error calling item for identifier \"\(String(describing: itemIdentifier))\": \(error)")
                completionHandler(nil, nil, nil, error)
                return
            }

            guard let item = itemOptional else {
                self.logger.error("Could not find item metadata, identifier: \(String(describing: itemIdentifier))")
                completionHandler(nil, nil, nil, CommonError.internalError)
                return
            }

            guard let itemCasted = item as? Item else {
                self.logger.error("Could not cast item to Item class, identifier: \(String(describing: itemIdentifier))")
                completionHandler(nil, nil, nil, CommonError.internalError)
                return
            }

#if os(macOS)
            // Check the version when doing a partial content fetch to avoid mixing contents from different file versions.
            if let requestedVersion = requestedVersion {
                guard requestedVersion.contentVersion == item.itemVersion?.contentVersion else {
                    self.logger.error("requestedVersion (\(String(describing: requestedVersion))) != item.itemVersion (\(String(describing: item.itemVersion)))")
                    completionHandler(nil, nil, nil, NSFileProviderError(.versionNoLongerAvailable))
                    return
                }
            }
#endif

            let internalCompletionHandler = { (url: URL?, item: NSFileProviderItem?,
                                               range: NSRange?,
                                               error: Error?) -> Void in
                let forkProgress = self.fetchResourceFork(sourceItem: itemCasted, url: url, item: item, error: error,
                                                          completionHandler: { (url: URL?, item: NSFileProviderItem?, error: Error?) -> Void in
                    completionHandler(url, item, range, error)
                })
                if let forkProgress = forkProgress {
                    progress.addChild(forkProgress, withPendingUnitCount: 10)
                }
            }

            // Adjust the range, if necessary.
            var extent: NSRange?
            if let requestedRange = range,
               let fileSize = item.documentSize??.intValue {
                extent = self.adjustRequestedRange(requestedRange: requestedRange, alignment: alignment, fileSize: fileSize)
            }

            self.retrieveContentStorageType(itemIdentifier: itemCasted.entry.id,
                                            requestedRevision: itemCasted.entry.revision) { contentStorageTypeOptional, errorOptional in
                if let error = errorOptional as NSError? {
                    self.logger.error("Error calling retrieveContentStorageType for identifier \"\(String(describing: itemIdentifier))\": \(error)")
                    completionHandler(nil, nil, nil, error)
                    return
                }

                guard let contentStorageType = contentStorageTypeOptional else {
                    self.logger.error("no error, but also no contentStorageType")
                    completionHandler(nil, nil, nil, CommonError.internalError)
                    return
                }

                let fetchContentsProgress: Progress
                switch contentStorageType {
                case .inline:
                    fetchContentsProgress = self.fetchContentsInline(
                        for: itemIdentifier,
                        version: requestedVersion,
                        range: extent,
                        request: request,
                        completionHandler: internalCompletionHandler)
                case .inChunkStore(let contentSha256S):
                    fetchContentsProgress = self.fetchContentsFromChunkStore(contentSha256S: contentSha256S,
                                                                             item: item,
                                                                             previousVersionFileURL: nil,
                                                                             completionHandler: internalCompletionHandler)
                case .resourceFork:
                    fatalError("Should not happen")
                }
                progress.addChild(fetchContentsProgress, withPendingUnitCount: 95)
            }
        }

        progress.addChild(itemProgress, withPendingUnitCount: 5)
        progress.cancellationHandler = { completionHandler(nil, nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }

        return progress
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                              version requestedVersion: NSFileProviderItemVersion?,
                              request: NSFileProviderRequest,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress
    {
        logger.debug("🧩 fetchContents(for:\(itemIdentifier.rawValue)) @ domainVersion(\(request.domainVersion?.description ?? "<nil>"))")

        return fetchContentsInternal(for: itemIdentifier,
                                     version: requestedVersion,
                                     range: nil,
                                     request: request,
                                     alignment: 0,
                                     completionHandler: { (url: URL?, item: NSFileProviderItem?, _, error: Error?) -> Void in
            completionHandler(url, item, error)
        })
    }

    func retrieveContentStorageType(itemIdentifier: DomainService.ItemIdentifier,
                                    requestedRevision: DomainService.Version,
                                    completionHandler: @escaping (DomainService.ContentStorageType?, Error?) -> Void) {
        let param: DomainService.FetchItemContentStorageTypeParameter
        param = DomainService.FetchItemContentStorageTypeParameter(itemIdentifier: itemIdentifier, requestedRevision: requestedRevision)
        self.connection.makeJSONCallWithReturn(param) { result in
            switch result {
            case .failure(let error):
                completionHandler(nil, error)
                return
            case .success(let result):
                completionHandler(result.response.contentStorageType, nil)
                return
            }
        }
    }

    func fetchContentsInline(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        range: NSRange?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange?, Error?) -> Void) -> Progress {

        let param: DomainService.DownloadItemParameter
        if let version = requestedVersion {
            param = DomainService.DownloadItemParameter(itemIdentifier: DomainService.ItemIdentifier(itemIdentifier),
                                                        requestedRevision: DomainService.Version(version),
                                                        range: range)
        } else {
            param = DomainService.DownloadItemParameter(itemIdentifier: DomainService.ItemIdentifier(itemIdentifier),
                                                        requestedRevision: nil,
                                                        range: range)
        }

        return connection.makeJSONCallWithReturn(param) { result in
            switch result {
            case .failure(let error):
                completionHandler(nil, nil, nil, error.toPresentableError())
            case .success((let response, let data)):
                do {
                    let dataURL = self.makeTemporaryURL("fetchedContents")
                    let returnedLength = NSRange(location: 0, length: data.count)

                    try data.write(to: dataURL)
                    completionHandler(dataURL, Item(response.item), returnedLength, nil)
                } catch let error {
                    completionHandler(nil, nil, nil, error.toPresentableError())
                }
            }
        }
    }
}

#if os(macOS)

extension Extension: NSFileProviderPartialContentFetching {
    public func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier,
                                     version requestedVersion: NSFileProviderItemVersion,
                                     request: NSFileProviderRequest,
                                     minimalRange range: NSRange,
                                     aligningTo alignment: Int,
                                     options: NSFileProviderFetchContentsOptions,
                                     completionHandler:
                                     @escaping (URL?, NSFileProviderItem?, NSRange,
                                                NSFileProviderMaterializationFlags,
                                                Error?) -> Void) -> Progress
    {

        var requestedRange: NSRange? = nil
        if UserDefaults.sharedContainerDefaults.supportBRM {
            requestedRange = range
        }

        logger.debug("""
                    🧩 fetchPartialContents(for:\(itemIdentifier.rawValue))
                    @ range(\(range.location),\(range.length))
                    domainVersion(\(request.domainVersion?.description ?? "<nil>"))
                    """)

        return fetchContentsInternal(for: itemIdentifier,
                                     version: options.contains(.strictVersioning) ? requestedVersion : nil,
                                     range: requestedRange,
                                     request: request,
                                     alignment: alignment,
                                     completionHandler: { (url: URL?, item: NSFileProviderItem?,
                                                           returnRange: NSRange?,
                                                           error: Error?) -> Void in
            if let returnRange = returnRange {
                completionHandler(url, item, returnRange, [], error)
            } else {
                completionHandler(url, item, range, [], error)
            }
        })
    }
}

#endif

extension Extension {
    func uploadThumbnail(item: DomainService.Entry,
                         originalContentType: UTType?,
                         url: URL,
                         remainingFields: NSFileProviderItemFields)
                            async throws -> (NSFileProviderItem?, NSFileProviderItemFields, Bool) {
        // Only attempt to upload thumbnails for files.
        guard item.type == .file else {
            return (Item(item), remainingFields, false)
        }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 2.0, representationTypes: [.thumbnail])
        if let originalContentType = originalContentType {
            request.contentType = originalContentType
        }

        let tempURL = makeTemporaryURL("quickLookOutput", "jpeg")
        do {
            try await QLThumbnailGenerator.shared.saveBestRepresentation(for: request, to: tempURL, contentType: UTType.jpeg.identifier)
        } catch {
            return (Item(item), remainingFields, false)
        }
        defer { try? FileManager().removeItem(at: tempURL) }
        defer {
            let mgr = FileManager()
            try? mgr.removeItem(at: tempURL)
        }

        guard let thumbnailData = try? Data(contentsOf: tempURL, options: .alwaysMapped) else {
            return (Item(item), remainingFields, false)
        }
        let param = DomainService.UpdateThumbnailParameter(identifier: item.id, existingRevision: item.revision)
        do {
            let resp = try await self.connection.makeJSONCall(param, thumbnailData)
            return (Item(resp.item), remainingFields, false)
        } catch {
            // If anything happens during thumbnail upload, return the successful previous content changes.
            return (Item(item), remainingFields, false)
        }
    }

    public func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                           contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress
    {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let (item, remainingFields, someBool) = try await self.modifyItemInternal(item,
                                                                                          baseVersion: version,
                                                                                          changedFields: changedFields,
                                                                                          contents: newContents,
                                                                                          options: options,
                                                                                          request: request,
                                                                                          progress: progress)
                completionHandler(item, remainingFields, someBool, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    private func uploadResourceFork(item: DomainService.Entry, fork: Data?, changedFields: NSFileProviderItemFields,
                                    updateResourceForkOnConflictedItem: Bool, contentType: UTType?, url: URL,
                                    parentProgress: Progress) async throws -> (NSFileProviderItem?, NSFileProviderItemFields, Bool) {
        guard let fork = fork else {
            if !updateResourceForkOnConflictedItem {
                return try await self.uploadThumbnail(item: item,
                                                      originalContentType: contentType,
                                                      url: url,
                                                      remainingFields: changedFields.removing(.contents))
            } else {
                return (Item(item), changedFields.removing(.contents), true)
            }
        }

        let contentStorageType: DomainService.ContentStorageType = .resourceFork
        let modifyContentsParameter = DomainService.ModifyContentsParameter(identifier: item.id,
                                                                            existingRevision: item.revision,
                                                                            contentStorageType: contentStorageType,
                                                                            updateResourceForkOnConflictedItem: updateResourceForkOnConflictedItem)
        return try await withCheckedThrowingContinuation { continuation in
            let callProgress = connection.makeJSONCall(modifyContentsParameter, fork) { res in
                switch res {
                case .success:
                    if !updateResourceForkOnConflictedItem {
                        Task {
                            let result = try await self.uploadThumbnail(item: item,
                                                                        originalContentType: contentType,
                                                                        url: url,
                                                                        remainingFields: changedFields.removing(.contents))
                            continuation.resume(returning: result)
                            return
                        }
                    } else {
                        continuation.resume(returning: (Item(item), changedFields.removing(.contents), true))
                        return
                    }
                case .failure(let error):
                    continuation.resume(throwing: error.toPresentableError())
                }
            }
            parentProgress.addChild(callProgress, withPendingUnitCount: 10)
        }
    }

    private func modifyItemInternal(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
                                    changedFields: NSFileProviderItemFields, contents newContents: URL?,
                                    options: NSFileProviderModifyItemOptions = [],
                                    request: NSFileProviderRequest,
                                    progress: Progress) async throws -> (NSFileProviderItem?, NSFileProviderItemFields, Bool) {
        logger.debug("🧩 modifyItem(for:\(item.itemIdentifier.rawValue)) @ domainVersion(\(request.domainVersion?.description ?? "<nil>"))")
        // The server API breaks out the different types of changes into separate calls:
        // content changes, thumbnail changes, and metadata changes (such as renames).
        // A differently designed server API might want to back all of these changes
        // by the same endpoint.

        if changedFields.contains(.contents) {
            let contentStorageType: DomainService.ContentStorageType
            var data: Data?
            let fork: Data?

            let contentType = item.contentType!
            switch contentType {
            case .symbolicLink:
                guard let accessor = item.symlinkTargetPath,
                    let targetPath = accessor else {
                        fatalError("couldn't get symlinkTargetPath on \(item)")
                }
                contentStorageType = .inline
                data = targetPath.utf8Data
                fork = nil
            case .folder:
                // Folders don't have contents in this sense. Modification of folder
                // contents goes through structural change methods.
                fatalError("folders should never get a modifyItem with .contents set")
            default:
                do {
                    guard let contents = newContents else {
                        fatalError(".contents set in changedFields, but no contents URL passed")
                    }

                    do {
                        let rsrcUrl = contents.appendingPathComponent("..namedfork/rsrc")
                        fork = try Data(contentsOf: rsrcUrl, options: .alwaysMapped)
                    } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
                        fork = nil
                    } catch let error {
                        fatalError("failed to read resource fork: \(error)")
                    }

                    if self.shouldUploadInChunks(itemTemplate: item) {
                        let (chunkWithSha256s, contentLength0) = try await self.uploadFileInChunks(contents: contents)
                        let contentLength = contentLength0
                        let chunkSha256s = chunkWithSha256s.map({ (arg0) -> String in
                            return arg0.sha256
                        })
                        let contentSha256S = DomainService.ContentSha256S(contentSha256List: chunkSha256s, contentLength: contentLength)
                        contentStorageType = .inChunkStore(contentSha256sOfDataChunks: contentSha256S)
                        data = nil
                    } else {
                        contentStorageType = .inline
                        data = try Data(contentsOf: contents, options: .alwaysMapped)
                    }
                } catch let error {
                    // Intentionally not handling errors here to provoke crashes.
                    fatalError("failed to read newContents: \(error)")
                }
            }

            let modifyContentsParameter = DomainService.ModifyContentsParameter(identifier: DomainService.ItemIdentifier(item.itemIdentifier),
                                                                                existingRevision: DomainService.Version(version),
                                                                                contentStorageType: contentStorageType,
                                                                                updateResourceForkOnConflictedItem: false)
            return try await withCheckedThrowingContinuation { continuation in
                let callProgress = connection.makeJSONCall(modifyContentsParameter, data) { res in
                    Task {
                        do {
                            switch res {
                            case .success(let resp):
                                guard resp.contentAccepted else {
                                    // The upload succeeds, but the server doesn’t accept new contents.
                                    // Inform the completion handler that the system no longer needs to apply the contents,
                                    // but that it needs to refetch them.
                                    // Report all remaining changes as pending.
                                    if let url = newContents {
                                        let result = try await self.uploadResourceFork(item: resp.item, fork: fork, changedFields: changedFields,
                                                                updateResourceForkOnConflictedItem: true, contentType: contentType, url: url,
                                                                parentProgress: progress)
                                        continuation.resume(returning: result)
                                    } else {
                                        continuation.resume(returning: (Item(resp.item), changedFields.removing(.contents), true))
                                    }
                                    return
                                }
                                guard let url = newContents else {
                                    assert(item.contentType == .symbolicLink)
                                    return continuation.resume(returning: (Item(resp.item), changedFields.removing(.contents), false))
                                }
                                let result = try await self.uploadResourceFork(item: resp.item,
                                                                               fork: fork,
                                                                               changedFields: changedFields,
                                                                               updateResourceForkOnConflictedItem: false,
                                                                               contentType: contentType,
                                                                               url: url,
                                                                               parentProgress: progress)
                                continuation.resume(returning: result)
                            case .failure(let error):
                                continuation.resume(throwing: error.toPresentableError())
                            }
                        } catch {
                            continuation.resume(throwing: error.toPresentableError())
                        }
                    }
                }
                progress.addChild(callProgress, withPendingUnitCount: fork != nil ? 90 : 100)
                return
            }
        } else if changedFields.contains(.parentItemIdentifier) &&
            item.parentItemIdentifier == .trashContainer {
            if UserDefaults.sharedContainerDefaults.trashDisabled {
                logger.debug("🌀 trashing disabled: moving back")
                // If the system trashes an item, but the trash is in a disabled state, move the item back.
                let param = DomainService.FetchItemParameter(itemIdentifier: DomainService.ItemIdentifier(item.itemIdentifier))
                return try await withCheckedThrowingContinuation { continuation in
                    let callProgress = connection.makeJSONCall(param) { res in
                        Task {
                            switch res {
                            case .failure(let error):
                                continuation.resume(throwing: error.toPresentableError())
                            case .success(let resp):
                                continuation.resume(returning: (Item(resp.item), changedFields.removing(.parentItemIdentifier), false))
                            }
                        }
                    }
                    progress.addChild(callProgress, withPendingUnitCount: 100)
                    return
                }
            }
            let param = DomainService.TrashItemParameter(itemIdentifier: DomainService.ItemIdentifier(item.itemIdentifier),
                                                         existingRevision: DomainService.Version(version))

            return try await withCheckedThrowingContinuation { continuation in
                let callProgress = connection.makeJSONCall(param) { res in
                    switch res {
                    case .failure(let error):
                        continuation.resume(throwing: error.toPresentableError())
                    case .success(let resp):
                        continuation.resume(returning: (Item(resp.item), changedFields.removing(.parentItemIdentifier), false))
                    }
                }
                progress.addChild(callProgress, withPendingUnitCount: 100)
            }
        } else if changedFields.contains(.parentItemIdentifier) &&
            UserDefaults.sharedContainerDefaults.syncChildrenBeforeParentMove {

            logger.debug("🚧 enforcing barrier before applying modifyItem(for:\(item.itemIdentifier.rawValue))")
            try await self.manager.waitForChanges(below: item.itemIdentifier)

            let parent = changedFields.contains(.parentItemIdentifier) ? DomainService.ItemIdentifier(item.parentItemIdentifier) : nil
            let param = DomainService.ModifyMetadataParameter(itemIdentifier: DomainService.ItemIdentifier(item.itemIdentifier),
                                                              existingRevision: DomainService.Version(version),
                                                              filename: changedFields.contains(.filename) ? item.filename : nil,
                                                              parent: parent,
                                                              metadata: DomainService.EntryMetadata(item, changedFields))
            return try await withCheckedThrowingContinuation { continuation in
                let subProgress = self.connection.makeJSONCall(param) { res in
                    switch res {
                    case .success(let resp):
                        continuation.resume(returning: (Item(resp.item), [], false))
                    case .failure(let error):
                        continuation.resume(throwing: error.toPresentableError())
                    }
                }
                progress.addChild(subProgress, withPendingUnitCount: 100)

                return
            }
        } else {
            let parent = changedFields.contains(.parentItemIdentifier) ? DomainService.ItemIdentifier(item.parentItemIdentifier) : nil
            let param = DomainService.ModifyMetadataParameter(itemIdentifier: DomainService.ItemIdentifier(item.itemIdentifier),
                                                              existingRevision: DomainService.Version(version),
                                                              filename: changedFields.contains(.filename) ? item.filename : nil,
                                                              parent: parent,
                                                              metadata: DomainService.EntryMetadata(item, changedFields))
            return try await withCheckedThrowingContinuation { continuation in
                let callProgress = connection.makeJSONCall(param) { res in
                    switch res {
                    case .success(let resp):
                        continuation.resume(returning: (Item(resp.item), [], false))
                    case .failure(let error):
                        continuation.resume(throwing: error.toPresentableError())
                    }
                }
                progress.addChild(callProgress, withPendingUnitCount: 100)
                return
            }
        }
    }
}

extension Extension {
    public func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                           options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                           completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let (item, remainingFields, someBool) = try await self.createItemInternal(basedOn: itemTemplate,
                                                                                          fields: fields,
                                                                                          contents: url,
                                                                                          options: options,
                                                                                          request: request,
                                                                                          progress: progress)
                completionHandler(item, remainingFields, someBool, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        progress.cancellationHandler = { completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        return progress
    }

    private func shouldUploadInChunks(itemTemplate: NSFileProviderItem) -> Bool {
        let pref = UserDefaults.sharedContainerDefaults.uploadNewFilesInChunks

        if !pref {
            return false
        }

        // The minimum size for chunked uploads is 100 MB.
        let minSizeOfFileForChunkedUpload = 100 * 1024 * 1024

        if let size = itemTemplate.documentSize,
           let size2 = size {
            // Don't upload chunks if the size is small.
            if size2.intValue < minSizeOfFileForChunkedUpload {
                return false
            }
            return true
        } else {
            self.logger.error("Unable to determine document size, defaulting to *not* upload in chunks. Item: \(String(describing: itemTemplate))")
            return false
        }
    }

    private func createItemInternal(basedOn itemTemplate: NSFileProviderItem,
                                    fields: NSFileProviderItemFields,
                                    contents url: URL?,
                                    options: NSFileProviderCreateItemOptions = [],
                                    request: NSFileProviderRequest,
                                    progress: Progress) async throws -> (NSFileProviderItem?, NSFileProviderItemFields, Bool) {
        logger.debug("🧩 createItem() @ domainVersion(\(request.domainVersion?.description ?? "<nil>"))")
        let type: DomainService.EntryType
        let contentStorageType: DomainService.ContentStorageType?
        let data: Data?
        let fork: Data?
        let contentType = itemTemplate.contentType
        switch contentType {
        case .folder?:
            type = .folder
            contentStorageType = nil
            data = nil
            fork = nil
        case .symbolicLink?:
            type = .symlink
            // Symlinks store their payload in the symlinkTargetPath property of
            // the item. Upload them as item data here (even though they are more
            // similar to an item property), so the server reports them
            // as part of the userInfo on the way back. See DomainService.Entry's
            // database initializer.
            if fields.contains(.contents),
                let targetPathOptional = itemTemplate.symlinkTargetPath,
                let targetPath = targetPathOptional {
                contentStorageType = .inline
                data = targetPath.utf8Data
            } else {
                contentStorageType = nil
                data = nil
            }
            fork = nil
        case .aliasFile?:
            type = .alias
            if fields.contains(.contents), let url = url, let urlData = try? Data(contentsOf: url) {
                contentStorageType = .inline
                data = urlData
            } else {
                contentStorageType = nil
                data = nil
            }
            fork = nil
        default:
            type = .file
            if fields.contains(.contents),
                let url = url {

                do {
                    let rsrcUrl = url.appendingPathComponent("..namedfork/rsrc")
                    fork = try Data(contentsOf: rsrcUrl, options: .alwaysMapped)
                } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
                    // Ignore "no such file" errors.
                    fork = nil
                }

                do {
                    if self.shouldUploadInChunks(itemTemplate: itemTemplate) {
                        let (chunkSha256sWithRanges, contentLength) = try await self.uploadFileInChunks(contents: url)
                        let chunkSha256s = chunkSha256sWithRanges.map { (arg0) -> String in
                            return arg0.sha256
                        }
                        let contentSha256S = DomainService.ContentSha256S(contentSha256List: chunkSha256s, contentLength: contentLength)
                        contentStorageType = .inChunkStore(contentSha256sOfDataChunks: contentSha256S)
                        data = nil
                    } else {
                        contentStorageType = .inline
                        data = try Data(contentsOf: url, options: .alwaysMapped)
                    }
                }
            } else {
                contentStorageType = nil
                data = nil
                fork = nil
            }
        }

        if options.contains(.mayAlreadyExist),
           type != .folder,    // Folders don’t have data.
           type != .symlink,   // Symlinks do have data.
           contentStorageType == nil {
            // The system is calling with an already-existing item that's dataless.
            // This only happens during a reimport, for items that the system hasn’t
            // materialized before. In this case, return nil (which causes the
            // system to delete the local item). After the system reenumerates the folder, it then recreates the file.
            return (nil, [], false)
        }

        let parent = itemTemplate.parentItemIdentifier
        let name = itemTemplate.filename
        let strategy: DomainService.CreateParameter.ConflictStrategy = options.contains(.mayAlreadyExist) ? .updateAlreadyExisting : .failOnExisting

        let param = DomainService.CreateParameter(parent: DomainService.ItemIdentifier(parent), name: name, type: type,
                             metadata: DomainService.EntryMetadata(itemTemplate, fields), conflict: strategy, contentStorageType: contentStorageType)
        return try await withCheckedThrowingContinuation { continuation in
            let callProgress = connection.makeJSONCall(param, data) { result in
                switch result {
                case .failure(let error):
                    continuation.resume(throwing: error.toPresentableError())
                case .success(let response):
                    guard let url = url else {
                        continuation.resume(returning: (Item(response.item), [], false))
                        return
                    }
                    do {
                        let result = try await self.uploadResourceFork(item: response.item,
                                                                       fork: fork,
                                                                       changedFields: [.contents],
                                                                       updateResourceForkOnConflictedItem: false,
                                                                       contentType: contentType,
                                                                       url: url,
                                                                       parentProgress: progress)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            progress.addChild(callProgress, withPendingUnitCount: fork != nil ? 90 : 100)
            return
        }
    }

    public func deleteItem(identifier itemIdentifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                           completionHandler: @escaping (Error?) -> Void) -> Progress {
        logger.debug("🧩 deleteItem(\(itemIdentifier.rawValue)) @ domainVersion(\(request.domainVersion?.description ?? "<nil>"))")

        let param = DomainService.DeleteItemParameter(itemIdentifier: DomainService.ItemIdentifier(itemIdentifier),
                                                      existingRevision: DomainService.Version(version),
                                                      recursiveDelete: options.contains(.recursive))
        let progress = connection.makeJSONCall(param) { result in
            switch result {
            // If the item is already gone, ignore the error.
            case .failure(CommonError.itemNotFound(_)):
                completionHandler(nil)
            case .failure(let error):
                completionHandler(error.toPresentableError())
            case .success:
                completionHandler(nil)
            }
        }
        progress.cancellationHandler = { completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) }
        return progress
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                           request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        logger.debug("🧩 enumerator(for \(containerItemIdentifier.rawValue, privacy: .public)) @ domainVersion(\(request.domainVersion?.description ?? "<nil>", privacy: .public))")
        switch containerItemIdentifier {
        case .workingSet:
            return WorkingSetEnumerator()
        case .trashContainer:
            if UserDefaults.sharedContainerDefaults.trashDisabled {
                logger.debug("🌀 trashing disabled: throwing noSuchItem error")
                throw NSFileProviderError(.noSuchItem)
            }
            return TrashEnumerator(connection: connection)
        default:
            //return ItemEnumerator(enumeratedItemIdentifier: containerItemIdentifier, connection: connection)
            return gitxetEnumerator(enumeratedItemIdentifier: containerItemIdentifier)
        }
    }

    public func importDidFinish(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

extension OptionSet {
    func removing(_ element: Element) -> Self {
        var mutable = self
        mutable.remove(element)
        return mutable
    }
}
