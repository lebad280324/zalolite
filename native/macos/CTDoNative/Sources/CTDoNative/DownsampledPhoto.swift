import SwiftUI
import AppKit
import ImageIO
import NativeBridge

final class ImageTransfer:NSObject,URLSessionDataDelegate,@unchecked Sendable {
 private var bytes=Data()
 private var owner:URLSession?
 private let completion:@Sendable(Result<Data,Error>)->Void
 private let limit:Int
 private init(limit:Int,_ completion:@escaping @Sendable(Result<Data,Error>)->Void){self.limit=limit;self.completion=completion}
 private func start(_ url:URL){let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=60;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;let queue=OperationQueue();queue.maxConcurrentOperationCount=1;owner=URLSession(configuration:config,delegate:self,delegateQueue:queue);owner?.dataTask(with:url).resume()}
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void){
  let status=(response as? HTTPURLResponse)?.statusCode ?? 0
  completionHandler(status==200 && response.expectedContentLength<=Int64(limit) ? .allow : .cancel)
 }
 func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data){if bytes.count+data.count>limit{dataTask.cancel()}else{bytes.append(data)}}
 func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?){if let error{completion(.failure(error))}else{completion(.success(bytes))};owner=nil;session.finishTasksAndInvalidate()}
 static func fetch(_ url:URL,limit:Int=20*1024*1024)async throws->Data {try await withCheckedThrowingContinuation{continuation in let request=ImageTransfer(limit:limit){continuation.resume(with:$0)};request.start(url)}}
}

private actor PhotoSlots {
    static let shared = PhotoSlots()
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func withSlot<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        if active < 4 { active += 1 }
        else { await withCheckedContinuation { waiting.append($0) } }
        defer {
            if waiting.isEmpty { active -= 1 }
            else { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}

@MainActor
final class PhotoCache {
    enum Size: Int, Sendable {
        case avatar = 192
        case inlinePhoto = 720
    }

    private struct Key: Hashable {
        let url: URL
        let size: Size
    }

    static let shared = PhotoCache()
    private let cache = ImageMemoryCache<Key>(byteLimit: 48 * 1024 * 1024, countLimit: 160)
    private var pending: [Key: Task<NSImage, Error>] = [:]
    private var failures: [Key: Date] = [:]

    func cached(_ url: URL, size: Size = .inlinePhoto) -> NSImage? {
        cache.image(for: Key(url: url, size: size))
    }

    func image(_ url: URL, size: Size = .inlinePhoto) async throws -> NSImage {
        let key = Key(url: url, size: size)
        if let image = cache.image(for: key) { return image }
        if let last = failures[key], Date().timeIntervalSince(last) < 15 { throw URLError(.resourceUnavailable) }
        if let existing = pending[key] { return try await existing.value }
        let task = Task { @MainActor in
            defer { pending[key] = nil }
            do {
                let cg = try await Task.detached(priority: .utility) {
                    try await Self.loadThumbnail(url, size: size)
                }.value
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                cache.insert(image, for: key, bytes: cg.bytesPerRow * cg.height)
                failures[key] = nil
                return image
            } catch {
                if failures.count >= 256 { failures.removeAll() }
                failures[key] = Date()
                throw error
            }
        }
        pending[key] = task
        return try await task.value
    }

    private nonisolated static func loadThumbnail(_ url: URL, size: Size) async throws -> CGImage {
        if url.isFileURL {
            return try await PhotoSlots.shared.withSlot {
                try thumbnail(CGImageSourceCreateWithURL(url as CFURL, sourceOptions), size: size)
            }
        }
        // A newly sent photo can take a few seconds to become available. Release the slot between retries.
        var lastError: Error = URLError(.badServerResponse)
        for delay: UInt64 in [0, 1_500_000_000, 4_000_000_000, 10_000_000_000] {
            if delay != 0 { try await Task.sleep(nanoseconds: delay) }
            do {
                return try await PhotoSlots.shared.withSlot {
                    let bytes = try await ImageTransfer.fetch(url)
                    guard !bytes.isEmpty else { throw URLError(.badServerResponse) }
                    return try thumbnail(CGImageSourceCreateWithData(bytes as CFData, sourceOptions), size: size)
                }
            } catch let error as URLError where error.code == .cannotDecodeContentData {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private nonisolated static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private nonisolated static func thumbnail(_ source: CGImageSource?, size: Size) throws -> CGImage {
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    /// The frame probe supplies synthetic photos without touching the network.
    func seedForDiagnostics(_ url: URL, _ image: NSImage) {
        cache.insert(image, for: Key(url: url, size: .inlinePhoto), bytes: Int(image.size.width * image.size.height) * 4)
    }
}

struct DownsampledPhoto: View {
 @Environment(\.transcriptColumnWidth) private var columnWidth
 @Environment(\.transcriptMediaActive) private var mediaActive
 private var imageWidth:CGFloat {min(280,max(80,(columnWidth-32)*0.78-22))}
 let url:URL
 var outgoing = false
 private var photoSize: CGSize {
  guard let image else { return CGSize(width:imageWidth,height:imageWidth*0.75) }
  return MessageMediaGeometry.fitted(image.size,in:CGRect(x:0,y:0,width:imageWidth,height:imageWidth*0.75),outgoing:outgoing).size
 }
 @State private var image:NSImage?
 @State private var loadedURL:URL?
 @State private var failed=false
 var body:some View {
  Group{
   if let image{Image(nsImage:image).resizable().scaledToFit().frame(width:photoSize.width,height:photoSize.height)}
   else{ZStack{Color.primary.opacity(0.055);Image(systemName:failed ? "photo.badge.exclamationmark" : "photo").font(.title2).foregroundStyle(.secondary)}.frame(width:imageWidth,height:imageWidth*0.75)}
  }.task(id:url.absoluteString+String(mediaActive)){guard mediaActive else{return};if loadedURL==url && image != nil{return};image=nil;failed=false;do{let decoded=try await PhotoCache.shared.image(url);guard !Task.isCancelled else{return};image=decoded;loadedURL=url}catch{if !Task.isCancelled{failed=true}}}

 }
}

/// Photos sent together, drawn as one grid like Zalo: rows of two or three square tiles.
struct PhotoAlbumGrid: View {
 let photos: [MessageSnapshot]
 let width: CGFloat
 private let gap: CGFloat = 2

 /// Row lengths: threes, with any remainder spread so no row holds a single photo.
 static func rowSizes(_ count: Int) -> [Int] {
  switch count {
  case ..<1: return []
  case 1, 2, 3: return [count]
  case 4: return [2, 2]
  default:
   switch count % 3 {
   case 0: return Array(repeating: 3, count: count / 3)
   case 1: return Array(repeating: 3, count: (count - 4) / 3) + [2, 2]
   default: return [2] + Array(repeating: 3, count: (count - 2) / 3)
   }
  }
 }

 var body: some View {
  let sizes = Self.rowSizes(photos.count)
  let starts = sizes.indices.map { sizes.prefix($0).reduce(0, +) }
  VStack(spacing: gap) {
   ForEach(Array(sizes.enumerated()), id: \.offset) { row, size in
    let side = (width - gap * CGFloat(size - 1)) / CGFloat(size)
    HStack(spacing: gap) {
     ForEach(photos[starts[row]..<starts[row] + size], id: \.id) { photo in
      PhotoTile(message: photo).frame(width: side, height: side)
     }
    }
   }
  }
  .frame(width: width)
  .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  .accessibilityElement(children: .contain)
  .accessibilityLabel("\(photos.count) ảnh")
 }
}

/// One square tile of an album; the photo fills it and opens in the viewer.
private struct PhotoTile: View {
 @Environment(\.transcriptMediaActive) private var mediaActive
 let message: MessageSnapshot
 @State private var image: NSImage?
 @State private var failed = false
 private var url: URL? { MediaSource.photo(message) }
 var body: some View {
  Button { if let url { NotificationCenter.default.post(name: .openImageViewer, object: url) } } label: {
   ZStack {
    Color.primary.opacity(0.055)
    if let image {
     Image(nsImage: image).resizable().scaledToFill()
    } else {
     Image(systemName: failed ? "photo.badge.exclamationmark" : "photo").font(.title3).foregroundStyle(.secondary)
    }
   }
   .clipped()
   .contentShape(Rectangle())
  }
  .buttonStyle(.plain)
  .help("Xem ảnh")
  .task(id: (url?.absoluteString ?? "") + String(mediaActive)) {
   guard mediaActive, let url, image == nil else { return }
   do { let decoded = try await PhotoCache.shared.image(url); if !Task.isCancelled { image = decoded } }
   catch { if !Task.isCancelled { failed = true } }
  }
 }
}
