import Darwin
import Dispatch
import Foundation

final class TerminationSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            self.continuation = continuation

            for signalNumber in [SIGINT, SIGTERM] {
                Darwin.signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: DispatchQueue.global()
                )
                source.setEventHandler { [weak self] in
                    self?.handleSignal()
                }
                sources.append(source)
            }

            sources.forEach { $0.resume() }
            lock.unlock()
        }
    }

    private func handleSignal() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let sources = self.sources
        self.sources.removeAll()
        lock.unlock()

        guard let continuation else { return }
        sources.forEach { $0.cancel() }
        continuation.resume()
    }
}
