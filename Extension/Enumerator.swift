/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An enumerator class that provides details about files and changes.
*/

import FileProvider
import Common
import os.log
import CoreServices
import UniformTypeIdentifiers

extension DomainService.RankToken {
    init(_ anchor: NSFileProviderSyncAnchor) throws {
        self = try JSONDecoder().decode(DomainService.RankToken.self, from: anchor.rawValue)
    }
}

extension NSFileProviderSyncAnchor {
    init(_ token: DomainService.RankToken) {
        self.init(rawValue: try! JSONEncoder().encode(token))
    }
}

extension NSFileProviderPage {
    init(_ cursor: Int64) {
        self.init(withUnsafeBytes(of: cursor) { Data($0) })
    }

    func toInt64() -> Int64 {
        if self == NSFileProviderPage.initialPageSortedByDate as NSFileProviderPage ||
            self == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage {
            return 0
        }
        var ret: Int64 = 0
        _ = withUnsafeMutableBytes(of: &ret) { ptr in
            self.rawValue.copyBytes(to: ptr)
        }
        return ret
    }
}

class ItemEnumerator: NSObject, NSFileProviderEnumerator
{
    private let logger = Logger(subsystem: "com.example.apple-samplecode.FruitBasket", category: "enumeration")

    let enumeratedItemIdentifier: DomainService.ItemIdentifier
    let connection: DomainConnection
    let recursive: Bool

    internal var presentationStatusTimerSource: DispatchSourceTimer? = nil
    internal let enumerationIndex = Int64.random(in: 0...Int64.max)

    override var description: String {
        var parts = [String]()
        parts.append("\(enumeratedItemIdentifier)")
        if recursive {
            parts.append("recursive")
        }
        if let timer = presentationStatusTimerSource {
            parts.append("ping via \(timer)s")
        }
        return "\(super.description) \(parts.joined(separator: ", "))"
    }

    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier, connection: DomainConnection, recursive: Bool = false) {
        self.enumeratedItemIdentifier = DomainService.ItemIdentifier(enumeratedItemIdentifier)
        self.connection = connection
        self.recursive = recursive
        super.init()
        setupForPresentationStatusTracking()
    }

    static let untrackedTypes: [UTType] = ["com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages-tef"].compactMap(UTType.init)

    static func shouldTrackPresentationStatus(for type: UTType) -> Bool {
        for untrackedType in ItemEnumerator.untrackedTypes where type.conforms(to: untrackedType) {
            return false
        }
        return true
    }

    func setupForPresentationStatusTracking() {
        connection.makeJSONCall(DomainService.FetchItemParameter(itemIdentifier: self.enumeratedItemIdentifier)) { response in
            switch response {
            case .failure:
                // Ignore failures.
                break
            case .success(let res):
                // When an app presents a file, the system opens an enumerator
                // on the file to track it. FruitBasket then displays a lock icon
                // in Finder next to any items that are in use. FruitBasket implements
                // the icon as an `NSFileProviderItemDecoration`, using the `inUseDecoration`
                // decoration identifier.
                if res.item.type == .file,
                    let type = UTType(tag: (res.item.name as NSString).pathExtension, tagClass: .filenameExtension, conformingTo: .data),
                    ItemEnumerator.shouldTrackPresentationStatus(for: type) {
                    self.pingPresentationStatus()

                    let source = DispatchSource.makeTimerSource(flags: [], queue: nil)
                    source.setEventHandler { [weak self] in
                        self?.pingPresentationStatus()
                    }
                    source.schedule(deadline: DispatchTime.now(),
                                    repeating: .milliseconds(Int(DomainService.PingLockParameter.pingInterval * 1000.0)), leeway: .milliseconds(500))
                    source.resume()
                    self.presentationStatusTimerSource = source
                }
            }
        }
    }

    func pingPresentationStatus() {
        // Regularly ping the server to inform it that the user is still looking at the item.
        let param = DomainService.PingLockParameter(identifier: enumeratedItemIdentifier,
                                                    owner: connection.displayName,
                                                    enumerationIndex: enumerationIndex)
        connection.makeJSONCall(param) { _ in }
    }

    func invalidate() {
        if let source = presentationStatusTimerSource {
            source.cancel()
            // Inform the server when the enumerator is no longer needed.
            let param = DomainService.RemoveLockParameter(identifier: enumeratedItemIdentifier, enumerationIndex: enumerationIndex)
            connection.makeJSONCall(param) { _ in }
        }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let param = DomainService.ListFolderParameter(folderIdentifier: enumeratedItemIdentifier, recursive: recursive,
                                                      startingCursor: page.toInt64())
        connection.makeJSONCall(param) { result in
            switch result {
            case .failure(let error):
                observer.finishEnumeratingWithError(error.toPresentableError())
            case .success(let response):
                observer.didEnumerate(response.entries.compactMap({
                    if $0.id == DomainConnection.trashItemIdentifier {
                        return nil
                    }
                    return Item($0)
                }))

                if let cursor = response.cursor {
                    observer.finishEnumerating(upTo: NSFileProviderPage(cursor))
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
            }
        }
    }

    func currentSyncAnchor() async -> NSFileProviderSyncAnchor? {
        do {
            let param = DomainService.LatestRankParameter(folderIdentifier: self.enumeratedItemIdentifier)
            let response = try await self.connection.makeJSONCall(param)
            return NSFileProviderSyncAnchor(response.rank)
        } catch {
            return nil
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        let rankToken: DomainService.RankToken
        do {
            rankToken = try DomainService.RankToken(anchor)
        } catch {
            observer.finishEnumeratingWithError(NSError(domain: NSFileProviderErrorDomain, code: NSFileProviderError.syncAnchorExpired.rawValue,
                                                        userInfo: nil))
            return
        }

        let param = DomainService.ListChangesParameter(folderIdentifier: enumeratedItemIdentifier, recursive: recursive, startingRank: rankToken)
        Task {
            do {
                let response = try await self.connection.makeJSONCall(param)
                if let deleted = response.deletedEntries,
                    !deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deleted.map(NSFileProviderItemIdentifier.init))
                }
                observer.didUpdate(response.entries.compactMap {
                    $0.id == DomainConnection.trashItemIdentifier ? nil : Item($0)
                })
                observer.finishEnumeratingChanges(upTo: NSFileProviderSyncAnchor(response.rank), moreComing: response.hasMore)
            } catch {
                observer.finishEnumeratingWithError(error.toPresentableError())
            }
        }
    }

}

//class WorkingSetEnumerator: ItemEnumerator {
//    init(connection: DomainConnection) {
//        // Enumerate everything from the root, recursively.
//        super.init(enumeratedItemIdentifier: .rootContainer, connection: connection, recursive: true)
//    }
//}

class WorkingSetEnumerator: gitxetEnumerator {
    init() {
        super.init(enumeratedItemIdentifier: NSFileProviderItemIdentifier("."))
    }
}

class TrashEnumerator: ItemEnumerator {
    init(connection: DomainConnection) {
        // Enumerate everything from the trash. This isn't recursive;
        // the File Provider framework asks for subitems if relevant.
        super.init(enumeratedItemIdentifier: .trashContainer, connection: connection, recursive: false)
    }
}

class gitxetEnumerator: NSObject, NSFileProviderEnumerator {
    private let logger = Logger(subsystem: "com.example.apple-samplecode.FruitBasket", category: "enumeration")
    
    let identifier: String
    func invalidate() {
        // todo
    }
    
    init(enumeratedItemIdentifier: NSFileProviderItemIdentifier) {
        self.identifier = enumeratedItemIdentifier.rawValue
        //print(enumeratedItemIdentifier)
        super.init()
    }

    
    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        logger.debug(" enumerating\(self.identifier, privacy: .public)")
        
        let entries = gitxetListFile(for: identifier)
        
        logger.debug(" enumerating\(entries, privacy: .public)")
        
        observer.didEnumerate(entries.compactMap( {
            return gitxetItem($0)
        }))
    }
    
    func gitxetListFile(for id: String) -> [gitxetDomainService.gitxetEntry] {
        let process = Process()
        process.launchPath = "git-xet"
        process.arguments = ["xetbox", "ls", id]
        
        let output = Pipe()
        
        process.standardOutput = output
        process.launch()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        
        let entries = try! JSONDecoder().decode([gitxetDomainService.gitxetEntry].self, from: data)
        
        return entries
    }
}

class gitxetItem: NSObject, NSFileProviderItemProtocol {
    let entry: gitxetDomainService.gitxetEntry
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    
    init(_ entry: gitxetDomainService.gitxetEntry) {
        self.entry = entry
        itemIdentifier = NSFileProviderItemIdentifier(entry.id)
        parentItemIdentifier = NSFileProviderItemIdentifier(entry.parent)
    }
    
    var filename: String {
        return entry.name
    }
    var contentType: UTType {
        switch entry.entry_type {
        case .folder, .root:
            return .folder
        case .file:
            return .item
        }
    }
    
    var capabilities: NSFileProviderItemCapabilities {
        var result: NSFileProviderItemCapabilities = [
            //.allowsAddingSubItems,
            .allowsContentEnumerating,
            //.allowsDeleting,
            .allowsReading,
            //.allowsRenaming,
            //.allowsReparenting,
            //.allowsWriting,
            //.allowsExcludingFromSync
        ]
        if !UserDefaults.sharedContainerDefaults.trashDisabled {
            result.insert(.allowsTrashing)
        }
        return result
    }
}

public enum gitxetDomainService {
    public static let rootItemCodingInfoKey = CodingUserInfoKey(rawValue: "rootItemIdentifier")!
    public static let trashItemCodingInfoKey = CodingUserInfoKey(rawValue: "trashItemIdentifier")!

    public enum EntryType: String, Codable {
        case file = "file"
        case folder = "folder"
        case root = "root"
    }

    public struct gitxetEntry: Codable {
        public let name: String
        public let id: String
        public let parent: String
        public let size: Int64
        public let entry_type: EntryType

        public init(name: String, id: String, parent: String, deleted: Bool, size: Int64, children: Int?,
                    type: EntryType) {
            self.name = name
            self.id = id
            self.parent = parent
            self.size = size
            self.entry_type = type
        }
    }
}
