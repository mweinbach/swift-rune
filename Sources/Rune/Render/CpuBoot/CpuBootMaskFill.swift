import Foundation

/// Shares outline scanlines between x phases and gives the largest groups to workers first.
/// The atlas holds the curve store stable until all participants have joined.
private final class CpuBootMaskBatch: @unchecked Sendable {
    let fills: [QueuedOutlineFill]
    let groups: [[UInt32]]
    let texels: UInt64
    private let lock = NSLock()
    private var next = 0
    private(set) var masks: [[UInt8]]

    init(_ fills: [QueuedOutlineFill]) {
        self.fills = fills
        let weighted = OutlineMaskFiller.shareRows(fills).map { indexes in
            let area = indexes.reduce(UInt64(0)) { sum, index in
                let r = fills[Int(index)].rect
                return sum + UInt64(r.z) * UInt64(r.w)
            }
            return (indexes, area)
        }
        self.groups = weighted.sorted { $0.1 > $1.1 }.map(\.0)
        self.texels = weighted.reduce(0) { $0 + $1.1 }
        self.masks = Array(repeating: [], count: fills.count)
    }

    func work(_ store: OutlineStore) {
        while let group = lock.withLock({ () -> [UInt32]? in
            guard next < groups.count else { return nil }
            defer { next += 1 }
            return groups[next]
        }) {
            var outputs = [[UInt8]](repeating: [], count: group.count)
            var census: OutlineFillCensus?
            OutlineMaskFiller.fillShared(OutlineF4.self, store: store, fills: fills, group: group,
                                         outs: &outputs, census: &census)
            lock.withLock {
                for (index, bytes) in zip(group, outputs) { masks[Int(index)] = bytes }
            }
        }
    }
}

extension CpuBootPool {
    func fillMasks(_ fills: [QueuedOutlineFill], store: OutlineStore) -> (masks: [[UInt8]], texels: UInt64) {
        let batch = CpuBootMaskBatch(fills)
        let count = min(threads, batch.groups.count, Int((batch.texels + 1_499) / 1_500))
        run(extra: max(0, count - 1)) { batch.work(store) }
        return (batch.masks, batch.texels)
    }
}
