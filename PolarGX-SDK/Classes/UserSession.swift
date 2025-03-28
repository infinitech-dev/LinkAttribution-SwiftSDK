import Foundation

/// Purpose: create user if needed by calling UpdateUser api.
/// Manage events since userId to be set and send to backend.
/// One UserSession instance will be created for only one user (userID)
actor UserSession {
    let organizationUnid: String
    let userID: String
    let apiService: APIService
    let trackingStorageURL: URL
    
    private var attributes = [String: String]()
    
    lazy var trackingEventQueue = TrackingEventQueue(fileUrl: trackingStorageURL, apiService: apiService)
    
    init(organizationUnid: String, userID: String, apiService: APIService, trackingStorageURL: URL) {
        self.organizationUnid = organizationUnid
        self.userID = userID
        self.apiService = apiService
        self.trackingStorageURL = trackingStorageURL
    }
    
    /// Keep all user attributes for next sending. I don't make sure server supports to merging existing user attributes and the new attributues
    func setAttributes(_ attributes: [String: String]) {
        Task {
            self.attributes = self.attributes.merging(attributes, uniquingKeysWith: { $1 })
            await startToUpdateUser()
        }
    }
    
    /// Sending user attributes and user id to backend. This API call will create an user if need. After succesful, we need to make `trackingEventQueue` to be ready and sending events if needed.
    /// Stop sending retrying process if server retuns status code #403.
    /// Retry when network connection issue, server returns status code #400 ...
    private func startToUpdateUser() async {
        var submitError: Error? = nil
        
        repeat {
            do {
                let attributes = self.attributes
                let user = UpdateUserModel(organizationUnid: organizationUnid, userID: userID, data: attributes)
                try await apiService.updateUser(user)
                
            }catch let error {
                if error.apiError?.httpStatus == 403 {
                    Logger.rlog("UpdateUser: ⛔️⛔️⛔️ INVALID appId OR apiKey! ⛔️⛔️⛔️")
                    submitError = nil
                    
                }else{
                    Logger.log("UpdateUser: failed ⛔️ + retrying 🔁: \(error)")
                    try? await Task.sleep(nanoseconds: 1_000_0000_000)
                    submitError = error
                }
            }
            
        }while submitError != nil
        
        if submitError == nil {
            await trackingEventQueue.setReady()
            await trackingEventQueue.sendEventsIfNeeded()
        }
    }
    
    /// Track event for user.
    func trackEvent(name: String, date: Date, attributes: [String: String]) async {
        await trackingEventQueue.push(TrackEventModel(
            organizationUnid: organizationUnid,
            userID: userID,
            eventName: name,
            eventTime: date,
            data: attributes
        ))
        await trackingEventQueue.sendEventsIfNeeded()
    }
}
