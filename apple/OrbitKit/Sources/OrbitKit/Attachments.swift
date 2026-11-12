import Foundation

public struct ChatAttachment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mime: String
    public var size: Int
    public var isImage: Bool { mime.hasPrefix("image/") }
    public init(id: String, name: String, mime: String, size: Int) {
        self.id = id; self.name = name; self.mime = mime; self.size = size
    }
    public var json: JSONValue { .object(["id": .string(id), "name": .string(name), "mime": .string(mime), "size": .number(Double(size))]) }
}

extension Message {
    public var attachments: [ChatAttachment] {
        (meta?["attachments"]?.array ?? []).compactMap { value in
            guard let id = value["id"]?.string, let name = value["name"]?.string,
                  let mime = value["mime"]?.string, let size = value["size"]?.number else { return nil }
            return ChatAttachment(id: id, name: name, mime: mime, size: Int(size))
        }
    }
}
