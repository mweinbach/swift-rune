import Foundation
import Testing
@testable import RuneRegister

@Suite("RuneRegister Tests")
struct RuneRegisterTests {
    private struct Item: Equatable, Sendable {
        var name: String
        var value: UInt32
    }

    @Test func collectOrdersByModuleThenOwnOrder() {
        let parts = [
            RegistryPart(module: "app::b", items: [Item(name: "b1", value: 0), Item(name: "b2", value: 0)]),
            RegistryPart(module: "app::a", items: [Item(name: "a1", value: 0)]),
        ]
        let names = RuneRegister.collect(parts).map(\.name)
        #expect(names == ["a1", "b1", "b2"])
    }

    @Test func collectEmptyIsEmpty() {
        let parts: [RegistryPart<Item>] = []
        #expect(RuneRegister.collect(parts).isEmpty)
    }

    @Test func mergeJoinsByNameAndKeepsFooterLast() {
        let own = [
            Item(name: "one", value: 1),
            Item(name: "two", value: 2),
            Item(name: "footer", value: 9),
        ]
        let more = [
            Item(name: "two", value: 20),
            Item(name: "new", value: 5),
        ]
        let out = RuneRegister.merge(own, with: more, name: \.name) { existing, incoming in
            existing.value += incoming.value
        }
        #expect(out == [
            Item(name: "one", value: 1),
            Item(name: "two", value: 22),
            Item(name: "new", value: 5),
            Item(name: "footer", value: 9),
        ])
    }

    @Test func mergeIntoEmptyOwn() {
        let out = RuneRegister.merge([], with: [Item(name: "x", value: 1)], name: \.name) { _, _ in }
        #expect(out == [Item(name: "x", value: 1)])
    }

    @Test func distributedRegistryCollectsInModuleOrder() async {
        let registry = DistributedRegistry<Item>()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                registry.register(module: "mod::two", Item(name: "w", value: 3))
            }
            group.addTask {
                registry.register(module: "mod::one", Item(name: "z", value: 1), Item(name: "y", value: 2))
            }
        }
        let names = registry.collect().map(\.name)
        #expect(names == ["z", "y", "w"])
    }
}
