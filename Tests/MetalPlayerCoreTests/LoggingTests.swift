import Foundation
import Testing

@testable import MetalPlayerCore

@Suite("AppLog & LogStore Tests", .serialized)
struct LoggingTests {
    @Test("LogStore correctly appends entries and adheres to capacity limit")
    func testLogStoreCapacity() {
        let store = LogStore(maxCapacity: 10, writeToDisk: false)
        for i in 1...15 {
            store.append(
                LogEntry(
                    level: .info,
                    category: .engine,
                    message: "Message \(i)"
                )
            )
        }

        let snapshot = store.snapshot()
        #expect(snapshot.count == 10)
        #expect(snapshot.first?.message == "Message 6")
        #expect(snapshot.last?.message == "Message 15")
    }

    @Test("AppLog routes logs into LogStore with accurate metadata")
    func testAppLogRouting() {
        let store = LogStore.shared
        let uniqueMarker = "AppLogTestMarker-\(UUID().uuidString)"
        AppLog.warning(.audio, uniqueMarker)

        let snapshot = store.snapshot()
        let matching = snapshot.first(where: { $0.message.contains(uniqueMarker) })
        #expect(matching != nil)
        #expect(matching?.level == .warning)
        #expect(matching?.category == .audio)
    }

    @Test("AppLog respects minimumLogLevel threshold and skips lower priority messages")
    func testAppLogMinimumLogLevelThreshold() {
        let previousLevel = AppLog.minimumLogLevel
        defer { AppLog.minimumLogLevel = previousLevel }

        AppLog.minimumLogLevel = .warning

        let store = LogStore.shared
        let debugMarker = "DebugMarker-\(UUID().uuidString)"
        let warningMarker = "WarningMarker-\(UUID().uuidString)"

        AppLog.debug(.engine, debugMarker)
        AppLog.warning(.engine, warningMarker)

        let snapshot = store.snapshot()
        #expect(snapshot.first(where: { $0.message.contains(debugMarker) }) == nil)
        #expect(snapshot.first(where: { $0.message.contains(warningMarker) }) != nil)
    }

    @Test("LogStore listeners receive live entries and can be removed via listenerId")
    func testLogStoreListenerAndRemoval() {
        let store = LogStore(maxCapacity: 50, writeToDisk: false)
        let uniqueMarker1 = "ListenerMarker1-\(UUID().uuidString)"
        let uniqueMarker2 = "ListenerMarker2-\(UUID().uuidString)"

        nonisolated(unsafe) var receivedCount = 0
        let listenerId = store.addListener { _ in
            receivedCount += 1
        }

        store.append(
            LogEntry(
                level: .error,
                category: .video,
                message: uniqueMarker1
            )
        )
        #expect(receivedCount == 1)

        store.removeListener(listenerId)

        store.append(
            LogEntry(
                level: .error,
                category: .video,
                message: uniqueMarker2
            )
        )
        #expect(receivedCount == 1)
    }

    @Test("High-concurrency stress test with multiple threads appending simultaneously")
    func testConcurrentLoggingStress() async {
        let store = LogStore(maxCapacity: 500, writeToDisk: false)

        await withTaskGroup(of: Void.self) { group in
            for threadIndex in 0..<10 {
                group.addTask {
                    for msgIndex in 0..<50 {
                        store.append(
                            LogEntry(
                                level: .info,
                                category: .engine,
                                message: "Thread \(threadIndex) Item \(msgIndex)"
                            )
                        )
                    }
                }
            }
        }

        let snapshot = store.snapshot()
        #expect(snapshot.count == 500)
    }

    @Test("AppLog supports string literals, host preset and custom LogCategory")
    func testDynamicLogCategory() {
        let previousLevel = AppLog.minimumLogLevel
        AppLog.minimumLogLevel = .debug
        defer { AppLog.minimumLogLevel = previousLevel }

        let customCategory: LogCategory = "CustomExtension"
        let marker1 = "CustomMsg-\(UUID().uuidString)"
        let marker2 = "LiteralMsg-\(UUID().uuidString)"
        let marker3 = "HostMsg-\(UUID().uuidString)"

        AppLog.info(customCategory, marker1)
        AppLog.info("DirectStringLiteral", marker2)
        AppLog.info(.host, marker3)

        let snapshot = LogStore.shared.snapshot()
        let entry1 = snapshot.first(where: { $0.message.contains(marker1) })
        let entry2 = snapshot.first(where: { $0.message.contains(marker2) })
        let entry3 = snapshot.first(where: { $0.message.contains(marker3) })

        #expect(entry1?.category == customCategory)
        #expect(entry1?.category.rawValue == "CustomExtension")

        #expect(entry2?.category == "DirectStringLiteral")
        #expect(entry2?.category.rawValue == "DirectStringLiteral")

        #expect(entry3?.category == .host)
        #expect(entry3?.category.rawValue == "Host")
    }
}
