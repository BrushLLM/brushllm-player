import Foundation
import Libmpv

/// Parses `mpv_node` trees (MPV_FORMAT_NODE) into Swift values.
///
/// mpv exposes structured data — `track-list`, `playlist`, `chapter-list` — as
/// node arrays of maps. The node memory belongs to mpv and is freed with
/// `mpv_free_node_contents`, so every parse copies values out.
enum MPVNodeParser {

    /// Reads a property as a node tree and parses it into Swift values.
    /// Returns nil when the property is unavailable.
    static func getProperty(_ controller: MPVController, _ name: String) -> Any? {
        guard let mpv = controller.mpv else { return nil }
        var node = mpv_node()
        guard mpv_get_property(mpv, name, MPV_FORMAT_NODE, &node) >= 0 else {
            return nil
        }
        defer { mpv_free_node_contents(&node) }
        return parse(&node)
    }

    static func parse(_ node: UnsafeMutablePointer<mpv_node>) -> Any? {
        switch node.pointee.format {
        case MPV_FORMAT_NONE:
            return nil
        case MPV_FORMAT_STRING:
            guard let cString = node.pointee.u.string else { return nil }
            return String(cString: cString)
        case MPV_FORMAT_FLAG:
            return node.pointee.u.flag != 0
        case MPV_FORMAT_INT64:
            return Int(node.pointee.u.int64)
        case MPV_FORMAT_DOUBLE:
            return node.pointee.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            return parseArray(node.pointee.u.list)
        case MPV_FORMAT_NODE_MAP:
            return parseMap(node.pointee.u.list)
        default:
            return nil
        }
    }

    private static func parseArray(_ listPointer: UnsafeMutablePointer<mpv_node_list>?) -> [Any] {
        guard let list = listPointer else { return [] }
        var items: [Any] = []
        items.reserveCapacity(Int(list.pointee.num))
        for index in 0..<Int(list.pointee.num) {
            if let item = parse(list.pointee.values + index) {
                items.append(item)
            }
        }
        return items
    }

    private static func parseMap(_ listPointer: UnsafeMutablePointer<mpv_node_list>?) -> [String: Any] {
        guard let list = listPointer else { return [:] }
        var map: [String: Any] = [:]
        for index in 0..<Int(list.pointee.num) {
            guard let key = list.pointee.keys[index] else { continue }
            let name = String(cString: key)
            if let value = parse(list.pointee.values + index) {
                map[name] = value
            }
        }
        return map
    }
}

/// Helpers for reading typed values out of parsed node maps.
extension Dictionary where Key == String {
    var intValue: Int? { self["id"] as? Int ?? self["index"] as? Int }
    var stringValue: String? { self["title"] as? String ?? self["filename"] as? String }
    var boolFlag: Bool? {
        if let flag = self["current"] as? Bool { return flag }
        if let string = self["current"] as? String { return string == "yes" }
        return nil
    }
}
