import Foundation
import UIKit

private func Log(_ sf: @autoclosure () -> String) {
    if PolarApp.isLoggingEnabled {
        print("[\(Configuration.Brand)/Debug] \(sf())")
    }
}

private func RLog(_ sf: @autoclosure () -> String) {
    print("[\(Configuration.Brand)] \(sf())")
}

@objc
public class PolarApp: NSObject {
    private let appId: String
    private let apiKey: String
    private let onLinkClickHandler: OnLinkClickHandler
    
    @objc public static var isLoggingEnabled = true
    @objc public static var isDevelopmentEnabled = false //for Polar team only
    
    private var trackingEventQueue: TrackingEventQueue!
    
    lazy var apiService = APIService(server: Configuration.Env.server)
    lazy var appDirectory = FileStorageURL.sdkDirectory.appendingSubDirectory(appId)
    
    private init(appId: String, apiKey: String, onLinkClickHandler: @escaping OnLinkClickHandler) {
        self.appId = appId
        self.apiKey = apiKey
        self.onLinkClickHandler = onLinkClickHandler
        
        super.init()
        
        self.startInitializingApp()
    }
    
    private func startInitializingApp() {
        let trackingEventStorageUrl = appDirectory.file(name: "tracking.json")
        trackingEventQueue = TrackingEventQueue(fileUrl: trackingEventStorageUrl)
        Log("Unsent tracking events stored in `\(trackingEventStorageUrl.absoluteString)`")

        apiService.defaultHeaders = [
            "x-api-key": apiKey
        ]
        
        let date = Date()
        Task {
            let launchEvent = TrackEventModel(
                organizationUnid: appId,
                eventName: "app_launch",
                eventTime: date,
                data: [:]
            )
            
            var initializazingError: Error? = nil
            repeat {
                do {
                    try await apiService.trackEvent(launchEvent)
                    try Task.checkCancellation()
                    Log("Initializing - successful ✅ with \(Configuration.Env.name) enviroment")
                    initializazingError = nil
                                        
                }catch let error where error is URLError {
                    Log("Initializing - failed ⛔️ + retrying 🔁: \(error)")
                    initializazingError = error
                    try? await Task.sleep(nanoseconds: 1_000_0000_000)
                    
                }catch let error {
                    Log("Initializing - failed ⛔️ + stopped ⛔️: \(error)")
                    initializazingError = nil
                    
                    if error.apiError?.httpStatus == 403 {
                        RLog("⛔️⛔️⛔️ INVALID appId or apiKey! ⛔️⛔️⛔️")
                    }
                }
            }while initializazingError != nil
            
            await trackingEventQueue.setTrackingQueueIsRunning(false)
            await startTrackingQueueIfNeeded()
        }
        
        startTrackingAppLifeCycle()
    }
    
    private func trackEvent(name: String, date: Date, attributes: [String: String]) async {
        await trackingEventQueue.push(TrackEventModel(
            organizationUnid: self.appId,
            eventName: name,
            eventTime: date,
            data: attributes
        ))
        await startTrackingQueueIfNeeded()
    }
    
    private func startTrackingQueueIfNeeded() async {
        guard await trackingEventQueue.trackingQueueIsRunning == false else {
            return
        }
        
        await trackingEventQueue.setTrackingQueueIsRunning(true)

        Task {
            do {
                while let event = await trackingEventQueue.willPop() {
                    try await apiService.trackEvent(event)
                    await trackingEventQueue.pop()
                }
                
            }catch let error {
                Log("Tracking - failed ⛔️ + stopped ⛔️: \(error)")
            }
            
            await trackingEventQueue.setTrackingQueueIsRunning(false)
        }
    }
    
    private func startTrackingAppLifeCycle() {
        let nc = NotificationCenter.default
        let queue = OperationQueue.main
        let track = { [weak self] (notification: Notification) in
            let date = Date()
            let eventName = switch notification.name {
            case UIApplication.willEnterForegroundNotification: "app_open"
            case UIApplication.didEnterBackgroundNotification: "app_close"
            case UIApplication.didBecomeActiveNotification: "app_active"
            case UIApplication.willResignActiveNotification: "app_inactive"
            case UIApplication.willTerminateNotification: "app_ternimate"
            default: "unknown_lifecycle"
            }
            Task { await self?.trackEvent(name: eventName, date: date, attributes: [:]) }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: queue, using: track)
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: queue, using: track)
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: queue, using: track)
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: queue, using: track)
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: queue, using: track)
    }
    
    private func handleOpenningURL(_ openningURL: URL, subDomain: String, slug: String, clickUnid: String?) async {
        let clickTime = Date()
        
        do {
            let linkData = try await apiService.getLinkData(domain: subDomain, slug: slug)
            var clickId = clickUnid;
            if clickId == nil {
                clickId = try await apiService.trackLinkClick(LinkClickModel(
                   trackClick: subDomain, slug: slug, clickTime: clickTime, deviceData: [:], additionalData: [:])
               )?.unid
            }
            
            DispatchQueue.main.sync {
                self.onLinkClickHandler(openningURL, linkData?.data?.content ?? [:], nil)
            }
            
            if let clickId = clickId {
                _ = try await apiService.updateLinkClick(clickUnid: clickId, sdkUsed: true)
            }
            
        }catch let error {
            DispatchQueue.main.async {
                self.onLinkClickHandler(openningURL, nil, error)
            }
        }
    }
}

//Access
public extension PolarApp {
    private static var _shared: PolarApp?
    @objc static var shared: PolarApp! {
        guard let instance = _shared else { fatalError("PolarApp hasn't been initialized!") }
        return instance
    }
        
    typealias OnLinkClickHandler = (_ link: URL, _ data: [String: Any]?, _ error: Error?) -> Void
    @objc static func initialize(appId: String, apiKey: String, onLinkClickHandler: @escaping OnLinkClickHandler)  {
        _shared = PolarApp(appId: appId, apiKey: apiKey, onLinkClickHandler: onLinkClickHandler)
    }
    
    @objc func trackEvent(name: String, attributes: [String: String]) {
        let date = Date()
        Task {
            await trackEvent(name: name, date: date, attributes: attributes)
        }
    }
    
    @discardableResult
    @objc func continueUserActivity(_ activity: NSUserActivity) -> Bool {
        switch activity.activityType {
        case NSUserActivityTypeBrowsingWeb:
            if let url = activity.webpageURL, let (subDomain, slug) = Formatter.validateSupportingURL(url) {
                Task { await handleOpenningURL(url, subDomain: subDomain, slug: slug, clickUnid: nil) }
                return true
            }
            
        default:
            assertionFailure("\(activity.activityType) ???")
        }
        
        return false
    }
    
    @discardableResult
    @objc func openUrl(_ url: URL) -> Bool {
        guard let (subDomain, slug) = Formatter.validateSupportingURL(url) else {
            return false
        }
        
        var urlComponents = URLComponents.init(url: url, resolvingAgainstBaseURL: false)
        urlComponents?.scheme = "https"
        let clickId = urlComponents?.queryItems?.first(where: { $0.name == "__clid" })?.value
        urlComponents?.queryItems = nil
        guard let httpsUrl = urlComponents?.url else {
            return false
        }
        
        Task { await handleOpenningURL(httpsUrl, subDomain: subDomain, slug: slug, clickUnid: clickId) }
        return true
    }
}
