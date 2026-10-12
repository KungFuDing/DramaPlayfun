#if DEBUG
import Foundation

// Keep fixture responses consistent when a UI test revisits a page after a mutation.
final class WelfareUITestAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var balance: Int64 = 20000
    private var autoPlayNext = "on"
    private var signDays: Int
    private var signed: Bool

    init() {
        signed = ProcessInfo.processInfo.arguments.contains("-WelfareSignedUITestFixture")
        signDays = signed ? 7 : 1
    }

    var snapshot: (balance: Int64, autoPlayNext: String, signDays: Int, signed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (balance, autoPlayNext, signDays, signed)
    }

    func setAutoPlay(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        autoPlayNext = value
    }

    func signIn() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !signed else { return false }
        balance += 30
        signDays = 2
        signed = true
        return true
    }
}
#endif
