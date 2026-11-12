import SwiftUI
import OrbitKit
import UniformTypeIdentifiers
import PhotosUI
import ImageIO
import QuickLook

struct AttachmentDraft: Identifiable, Sendable {
    let id: String
    let name: String
    let mime: String
    let data: Data
    var uploaded: ChatAttachment?
    var metadata: ChatAttachment { uploaded ?? ChatAttachment(id: id, name: name, mime: mime, size: data.count) }

    static func prepare(name: String, data: Data) throws -> AttachmentDraft {
        var name = URL(fileURLWithPath: name).lastPathComponent
        var data = data
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .image) == true, let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
            let needsResize = !["png", "jpg", "jpeg", "webp", "gif"].contains(ext) || (ext == "gif" && CGImageSourceGetCount(source) > 1) || (properties?[kCGImagePropertyOrientation] as? Int ?? 1) != 1 || data.count > 2 * 1024 * 1024 || max(width, height) > 2400
            // Photos keep their pixels but never their GPS location: a lossless copy without location metadata.
            var stripped: Data?
            if !needsResize, let sourceType = CGImageSourceGetType(source) {
                let output = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(output, sourceType, 1, nil),
                   CGImageDestinationCopyImageSource(destination, source, [kCGImageMetadataShouldExcludeGPS: true] as CFDictionary, nil) {
                    stripped = output as Data
                }
            }
            if let stripped { data = stripped } else {
                // Re-encoding draws only the pixels, so all metadata (location included) is dropped.
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceCreateThumbnailWithTransform: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AttachmentIssue.invalidPhoto }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AttachmentIssue.invalidPhoto }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw AttachmentIssue.invalidPhoto }
                data = output as Data
                name = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + ".jpg"
            }
        }
        guard !data.isEmpty, data.count <= 5 * 1024 * 1024 else { throw AttachmentIssue.tooLarge }
        let allowed = Set(["jpg","jpeg","png","gif","webp","pdf","txt","md","csv","tsv","json","html","xml","log","doc","docx","xls","xlsx","ppt","pptx","rtf","py","js","ts","swift","c","cpp","h","java","go","rs","sql","yaml","yml"])
        let finalExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        guard allowed.contains(finalExtension) else { throw AttachmentIssue.unsupported }
        let mime = UTType(filenameExtension: finalExtension)?.preferredMIMEType ?? "text/plain"
        return AttachmentDraft(id: "draft-" + UUID().uuidString, name: name, mime: mime, data: data)
    }

    static func read(_ url: URL) async throws -> AttachmentDraft {
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 30 * 1024 * 1024 else { throw AttachmentIssue.tooLarge }
            return try prepare(name: url.lastPathComponent, data: Data(contentsOf: url))
        }.value
    }
}

enum AttachmentIssue: LocalizedError {
    case tooLarge, unsupported, invalidPhoto, tooMany, combinedSize
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Files must be 5 MB or smaller. Export a smaller copy and try again."
        case .unsupported: return "Try a photo, PDF, Word document, spreadsheet, presentation or text file."
        case .invalidPhoto: return "Couldn't read that photo. Try exporting it as JPEG or PNG."
        case .tooMany: return "You can attach up to six files per message."
        case .combinedSize: return "Keep attachments under 10 MB combined per message."
        }
    }
}

@MainActor final class AttachmentMemory {
    static let shared = AttachmentMemory()
    private let cache = NSCache<NSString, NSData>()
    private init() { cache.totalCostLimit = 20 * 1024 * 1024 }
    func get(_ id: String) -> Data? { cache.object(forKey: id as NSString) as Data? }
    func put(_ data: Data, id: String) { cache.setObject(data as NSData, forKey: id as NSString, cost: data.count) }
}

extension AppModel {
    func addAttachment(_ draft: AttachmentDraft) {
        guard pendingAttachments.count < 6 else { banner = AttachmentIssue.tooMany.localizedDescription; return }
        guard pendingAttachments.reduce(draft.data.count, { $0 + $1.data.count }) <= 10 * 1024 * 1024 else { banner = AttachmentIssue.combinedSize.localizedDescription; return }
        AttachmentMemory.shared.put(draft.data, id: draft.id)
        pendingAttachments.append(draft)
        chatJumpRequest += 1
    }
    func importAttachments(_ urls: [URL]) {
        Task {
            preparingAttachments = true
            defer { preparingAttachments = false }
            for url in urls {
                do { addAttachment(try await AttachmentDraft.read(url)) }
                catch { banner = error.localizedDescription }
            }
        }
    }
    func importProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.importAttachments([url]) }
                }
            } else if let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                let ext = UTType(identifier)?.preferredFilenameExtension ?? "png"
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                    Task { @MainActor in
                        guard let data else { self.banner = error?.localizedDescription ?? "Couldn't read that image"; return }
                        do { self.addAttachment(try AttachmentDraft.prepare(name: "Image.\(ext)", data: data)) }
                        catch { self.banner = error.localizedDescription }
                    }
                }
            }
        }
        return true
    }
}

struct AttachmentDraftStrip: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(model.pendingAttachments) { draft in
                    HStack(spacing: 8) {
                        if draft.mime.hasPrefix("image/"), let image = attachmentImage(draft.data) {
                            image.resizable().scaledToFill().frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 8))
                        } else { Image(systemName: "doc.text").font(.title3).foregroundStyle(.secondary).frame(width: 28) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(draft.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(draft.data.count), countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: 135, alignment: .leading)
                        Button { model.pendingAttachments.removeAll { $0.id == draft.id } } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Remove \(draft.name)")
                    }
                    .padding(8).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                }
            }
        }.padding(.horizontal, 5)
    }
}

struct AttachmentCard: View {
    let attachment: ChatAttachment
    @EnvironmentObject var model: AppModel
    @State private var data: Data?
    @State private var loading = false
    @State private var error: String?
    @State private var previewURL: URL?
    @State private var previewDirectory: URL?

    var body: some View {
        Button { Task { await preview() } } label: {
            VStack(alignment: .leading, spacing: 0) {
                if attachment.isImage, let data, let image = attachmentImage(data) {
                    image.resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                HStack(spacing: 10) {
                    Image(systemName: attachment.isImage ? "photo" : "doc.text").font(.system(size: 19)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attachment.name).font(.system(size: 13, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(error ?? ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                            .font(.system(size: 11)).foregroundStyle(error == nil ? Color.secondary : .orange).lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if loading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(.secondary) }
                }.padding(12)
            }
            .frame(maxWidth: 280, alignment: .leading)
            .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open attachment \(attachment.name)")
        .task(id: attachment.id) {
            data = AttachmentMemory.shared.get(attachment.id)
            if data == nil, attachment.isImage { await load() }
        }
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, value in if value == nil { cleanupPreview() } }
        .onDisappear { cleanupPreview() }
    }
    private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            guard let api = model.api else { return }
            data = try await api.attachmentData(id: attachment.id)
            if let data { AttachmentMemory.shared.put(data, id: attachment.id) }
        } catch { self.error = "Couldn't load. Tap to retry." }
    }
    private func preview() async {
        if data == nil { await load() }
        guard let data else { return }
        do {
            cleanupPreview()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Orbit-preview-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            previewDirectory = directory
            let name = URL(fileURLWithPath: attachment.name).lastPathComponent
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            previewURL = url
        } catch { self.error = "Couldn't open this attachment." }
    }
    private func cleanupPreview() {
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
    }
}

private func attachmentImage(_ data: Data) -> Image? {
    #if os(macOS)
    guard let image = NSImage(data: data) else { return nil }
    return Image(nsImage: image)
    #else
    guard let image = UIImage(data: data) else { return nil }
    return Image(uiImage: image)
    #endif
}
