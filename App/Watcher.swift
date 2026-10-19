// FSEvents watcher for the vault paths and the config folder (one stream for all of them), recursive by default (that's how FSEvents
// works -- there's no separate "recursive" flag). Any real change, including a
// `git commit` made in a terminal (touches .git/HEAD, refs, index -- already covered
// since .git lives inside the watched path), fires `onEvents` after FSEvents' own
// ~2s coalescing latency. No extra debounce needed on top of that. Which events matter
// (vault vs. ignored path vs. config.json) is decided by AppDelegate.handleEvents.
import CoreServices
import Foundation

final class VaultWatcher {
    private var stream: FSEventStreamRef?
    var onEvents: (([String]) -> Void)?

    func start(paths: [String]) {
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<VaultWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.onEvents?(paths)
        }
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0, // latency: the debounce
            // UseCFTypes is required for eventPaths to arrive as a CFArray of CFString
            // (paths) -- without it, eventPaths is a raw char** and bridging it to
            // NSArray/[String] as below is a straight segfault.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
