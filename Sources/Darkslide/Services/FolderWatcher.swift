import Foundation

/// Watches the open folder for new or removed files (an editor saving a JPEG next to the
/// RAW, a card finishing a copy). Coalesces bursts into one callback.
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var pending: DispatchWorkItem?
    var onChange: (() -> Void)?

    func watch(_ url: URL) {
        stop()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            pending?.cancel()
            let w = DispatchWorkItem { self.onChange?() }
            pending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)   // editors write in several steps
        }
        s.setCancelHandler { [fd = self.fd] in close(fd) }
        s.resume()
        source = s
    }

    func stop() {
        source?.cancel(); source = nil; fd = -1
    }
    deinit { stop() }
}
