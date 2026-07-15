import Foundation

enum DarwinNotifier {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyZone(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }
    
    static func observe(_ name: String, callback: @escaping () -> Void) -> DarwinObserverToken {
        let token = DarwinObserverToken(name: name, callback: callback)
        token.register()
        return token
    }
}

final class DarwinObserverToken {
    let name: String
    let callback: () -> Void
    private var observer: UnsafeMutableRawPointer?
    
    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback
    }
    
    func register() {
        let observerPtr = Unmanaged.passUnretained(self).toOpaque()
        self.observer = observerPtr
        
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer = observer else { return }
            let token = Unmanaged<DarwinObserverToken>.fromOpaque(observer).takeUnretainedValue()
            token.callback()
        }
        
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyZone(),
            observerPtr,
            callback,
            name as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    deinit {
        if let observer = observer {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyZone(),
                observer,
                CFNotificationName(rawValue: name as CFString),
                nil
            )
        }
    }
}
