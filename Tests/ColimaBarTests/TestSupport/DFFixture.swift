import Foundation

@testable import ColimaBar

/// Builds the body of `GET /system/df` for tests.
enum DFFixture {
    static let ctrID = String(repeating: "c1", count: 32)

    static func image(
        _ id: String, tags: [String]?, size: Int64, containers: Int = 0, shared: Int64 = 0, created: Int = 1_700_000_000
    ) -> String {
        let t = tags.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        return
            #"{"Id":"\#(id)","RepoTags":\#(t),"Size":\#(size),"SharedSize":\#(shared),"Created":\#(created),"Containers":\#(containers)}"#
    }

    static func volume(_ name: String, size: Int64?, refs: Int = 0, labels: String = "null") -> String {
        let usage = size.map { #"{"Size":\#($0),"RefCount":\#(refs)}"# } ?? "null"
        return #"{"Name":"\#(name)","Labels":\#(labels),"UsageData":\#(usage)}"#
    }

    static func container(
        _ id: String, name: String, state: String = "exited", size: Int64 = 0, labels: String = "null"
    ) -> String {
        #"{"Id":"\#(id)","Names":["/\#(name)"],"Image":"img:1","Labels":\#(labels),"SizeRw":\#(size),"State":"\#(state)"}"#
    }

    static func cache(
        _ id: String, type: String = "regular", size: Int64, inUse: Bool = false, shared: Bool = false,
        description: String = "", lastUsed: String? = nil
    ) -> String {
        let used = lastUsed.map { "\"\($0)\"" } ?? "null"
        return
            #"{"ID":"\#(id)","Type":"\#(type)","Description":"\#(description)","Size":\#(size),"InUse":\#(inUse),"Shared":\#(shared),"LastUsedAt":\#(used)}"#
    }

    static func body(
        images: [String] = [], containers: [String] = [], volumes: [String] = [], cache: [String] = []
    ) -> String {
        #"{"Images":[\#(images.joined(separator: ","))],"Containers":[\#(containers.joined(separator: ","))],"Volumes":[\#(volumes.joined(separator: ","))],"BuildCache":[\#(cache.joined(separator: ","))]}"#
    }

    static func df(
        images: [String] = [], containers: [String] = [], volumes: [String] = [], cache: [String] = []
    ) throws -> APIDF {
        let text = body(images: images, containers: containers, volumes: volumes, cache: cache)
        return try JSONDecoder().decode(APIDF.self, from: Data(text.utf8))
    }
}
