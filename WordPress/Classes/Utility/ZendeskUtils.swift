import Foundation
import ZendeskSDK
import CoreTelephony
import WordPressAuthenticator

extension NSNotification.Name {
    static let ZendeskPushNotificationReceivedNotification = NSNotification.Name(rawValue: "ZendeskPushNotificationReceivedNotification")
    static let ZendeskPushNotificationClearedNotification = NSNotification.Name(rawValue: "ZendeskPushNotificationClearedNotification")
}

@objc extension NSNotification {
    public static let ZendeskPushNotificationReceivedNotification = NSNotification.Name.ZendeskPushNotificationReceivedNotification
    public static let ZendeskPushNotificationClearedNotification = NSNotification.Name.ZendeskPushNotificationClearedNotification
}

/// This class provides the functionality to communicate with Zendesk for Help Center and support ticket interaction,
/// as well as displaying views for the Help Center, new tickets, and ticket list.
///
@objc class ZendeskUtils: NSObject {

    // MARK: - Public Properties

    static var sharedInstance: ZendeskUtils = ZendeskUtils()
    static var zendeskEnabled = false
    @objc static var unreadNotificationsCount = 0

    @objc static var showSupportNotificationIndicator: Bool {
        return unreadNotificationsCount > 0
    }

    struct PushNotificationIdentifiers {
        static let key = "type"
        static let type = "zendesk"
    }

    // MARK: - Private Properties

    private override init() {}
    private var sourceTag: WordPressSupportSourceTag?

    private var userName: String?
    private var userEmail: String?
    private var deviceID: String?
    private var haveUserIdentity = false
    private var alertNameField: UITextField?

    private static var zdAppID: String?
    private static var zdUrl: String?
    private static var zdClientId: String?
    private static var presentInController: UIViewController?

    private static let sourcePlatform = "mobile_-_ios"
    private static var appVersion: String {
        return Bundle.main.shortVersionString() ?? Constants.unknownValue
    }

    private static var appLanguage: String {
        guard let lang = Locale.current.languageCode else {
            return Constants.unknownValue
        }
        return lang
    }



    // MARK: - Public Methods

    @objc static func setup() {
        guard getZendeskCredentials() == true else {
            return
        }

        ZDKConfig.instance().initialize(withAppId: zdAppID,
                                        zendeskUrl: zdUrl,
                                        clientId: zdClientId)

        ZendeskUtils.sharedInstance.haveUserIdentity = getUserProfile()
        toggleZendesk(enabled: true)
        setAppearance()

        // User has accessed a single ticket view, typically via the Zendesk Push Notification alert.
        // In this case, we'll clear the Push Notification indicators.
        NotificationCenter.default.addObserver(self, selector: #selector(ticketViewed(_:)), name: NSNotification.Name(rawValue: ZDKAPI_CommentListStarting), object: nil)

        // Get unread notification count from User Defaults.
        unreadNotificationsCount = UserDefaults.standard.integer(forKey: Constants.userDefaultsZendeskUnreadNotifications)

        //If there are any, post NSNotification so the unread indicators are displayed.
        if unreadNotificationsCount > 0 {
            postNotificationReceived()
        }

        observeZendeskNotifications()
    }

    // MARK: - Show Zendesk Views

    /// Displays the Zendesk Help Center from the given controller, filtered by the mobile category and articles labelled as iOS.
    ///
    func showHelpCenterIfPossible(from controller: UIViewController, with sourceTag: WordPressSupportSourceTag? = nil) {

        ZendeskUtils.configureViewController(controller)

        // Since user information is not needed to display the Help Center,
        // if a user identity has not been created, create an empty identity.
        if !ZendeskUtils.sharedInstance.haveUserIdentity {
            let zendeskIdentity = ZDKAnonymousIdentity()
            ZDKConfig.instance().userIdentity = zendeskIdentity
        }

        self.sourceTag = sourceTag

        guard let helpCenterContentModel = ZDKHelpCenterOverviewContentModel.defaultContent() else {
            DDLogInfo("Zendesk helpCenterContentModel creation failed.")
            return
        }

        helpCenterContentModel.groupType = .category
        helpCenterContentModel.groupIds = [Constants.mobileCategoryID]
        helpCenterContentModel.labels = [Constants.articleLabel]
        WPAnalytics.track(.supportHelpCenterViewed)

        // Set the ability to 'Contact Us' from the Help Center according to usingAnonymousIDForHelpCenter.
        ZDKHelpCenter.setUIDelegate(self)
        _ = active()

        ZDKHelpCenter.presentOverview(ZendeskUtils.presentInController, with: helpCenterContentModel)
    }

    /// Displays the Zendesk New Request view from the given controller, for users to submit new tickets.
    ///
    func showNewRequestIfPossible(from controller: UIViewController, with sourceTag: WordPressSupportSourceTag? = nil) {

        ZendeskUtils.configureViewController(controller)

        ZendeskUtils.createIdentity { success in
            guard success else {
                return
            }

            self.sourceTag = sourceTag

            ZDKRequests.presentRequestCreation(with: ZendeskUtils.presentInController)
            WPAnalytics.track(.supportNewRequestViewed)
            self.createRequest()
        }
    }

    /// Displays the Zendesk Request List view from the given controller, allowing user to access their tickets.
    ///
    func showTicketListIfPossible(from controller: UIViewController, with sourceTag: WordPressSupportSourceTag? = nil) {

        ZendeskUtils.configureViewController(controller)

        ZendeskUtils.createIdentity { success in
            guard success else {
                return
            }

            self.sourceTag = sourceTag

            ZDKRequests.presentRequestList(with: ZendeskUtils.presentInController)
            WPAnalytics.track(.supportTicketListViewed)
        }
    }

    /// Displays an alert allowing the user to change their Support email address.
    ///
    func showSupportEmailPrompt(from controller: UIViewController, completion: @escaping (Bool) -> Void) {
        ZendeskUtils.configureViewController(controller)

        ZendeskUtils.getUserInformationAndShowPrompt(withName: false) { success in
            completion(success)
        }
    }

    // MARK: - Device Registration

    /// Sets the device ID to be registered with Zendesk for push notifications.
    /// Actual registration is done when a user selects one of the Zendesk views.
    ///
    static func setNeedToRegisterDevice(_ identifier: String) {
        ZendeskUtils.sharedInstance.deviceID = identifier
    }

    /// Unregisters the device ID from Zendesk for push notifications.
    ///
    static func unregisterDevice(_ identifier: String) {
        ZDKConfig.instance().disablePush(identifier) { status, error in
            if let error = error {
                DDLogInfo("Zendesk couldn't unregistered device: \(identifier). Error: \(error)")
            } else {
                DDLogDebug("Zendesk successfully unregistered device: \(identifier)")
            }
        }
    }

    // MARK: - Push Notifications

    /// This handles in-app Zendesk push notifications.
    /// If a Zendesk view is being displayed, an alert will appear allowing
    /// the user to view the updated ticket.
    ///
    static func handlePushNotification(_ userInfo: NSDictionary) {
        WPAnalytics.track(.supportReceivedResponseFromSupport)
        guard zendeskEnabled == true,
            let payload = userInfo as? [AnyHashable: Any] else {
                DDLogInfo("Zendesk push notification payload invalid.")
                return
        }

        ZDKPushUtil.handlePush(payload,
                               for: UIApplication.shared,
                               presentationStyle: .formSheet,
                               layoutGuide: ZDKLayoutRespectTop,
                               withAppId: zdAppID,
                               zendeskUrl: zdUrl,
                               clientId: zdClientId)
    }

    /// This handles all Zendesk push notifications. (The in-app flow goes through here as well.)
    /// When a notification is received, an NSNotification is posted to allow
    /// the various indicators to be displayed.
    ///
    static func pushNotificationReceived() {
        unreadNotificationsCount += 1
        saveUnreadCount()
        postNotificationReceived()
    }

    /// When a user views the Ticket List, this is called to:
    /// - clear the notification count
    /// - update the application badge count
    /// - post an NSNotification so the various indicators can be cleared.
    ///
    static func pushNotificationRead() {
        UIApplication.shared.applicationIconBadgeNumber -= unreadNotificationsCount
        unreadNotificationsCount = 0
        saveUnreadCount()
        postNotificationRead()
    }

    // MARK: - Helpers

    /// Returns the user's Support email address.
    ///
    static func userSupportEmail() -> String? {
        let _ = getUserProfile()
        return ZendeskUtils.sharedInstance.userEmail
    }

}

// MARK: - Private Extension

private extension ZendeskUtils {

    static func getZendeskCredentials() -> Bool {
        guard let appId = ApiCredentials.zendeskAppId(),
            let url = ApiCredentials.zendeskUrl(),
            let clientId = ApiCredentials.zendeskClientId(),
            appId.count > 0,
            url.count > 0,
            clientId.count > 0 else {
                DDLogInfo("Unable to get Zendesk credentials.")
                toggleZendesk(enabled: false)
                return false
        }

        zdAppID = appId
        zdUrl = url
        zdClientId = clientId
        return true
    }

    static func toggleZendesk(enabled: Bool) {
        zendeskEnabled = enabled
        DDLogInfo("Zendesk Enabled: \(enabled)")
    }

    static func createIdentity(completion: @escaping (Bool) -> Void) {

        // If we already have an identity, do nothing.
        guard ZendeskUtils.sharedInstance.haveUserIdentity == false else {
            DDLogDebug("Using existing Zendesk identity: \(ZendeskUtils.sharedInstance.userEmail ?? ""), \(ZendeskUtils.sharedInstance.userName ?? "")")
            completion(true)
            return
        }

        /*
         1. Attempt to get user information from User Defaults.
         2. If we don't have the user's information yet, attempt to get it from the account/site.
         3. Prompt the user for email & name, pre-populating with user information obtained in step 1.
         4. Create Zendesk identity with user information.
         */

        if getUserProfile() {
            ZendeskUtils.createZendeskIdentity { success in
                guard success else {
                    DDLogInfo("Creating Zendesk identity failed.")
                    completion(false)
                    return
                }
                DDLogDebug("Using User Defaults for Zendesk identity.")
                ZendeskUtils.sharedInstance.haveUserIdentity = true
                completion(true)
                return
            }
        }

        ZendeskUtils.getUserInformationAndShowPrompt(withName: true) { success in
            completion(success)
        }
    }

    static func getUserInformationAndShowPrompt(withName: Bool, completion: @escaping (Bool) -> Void) {
        ZendeskUtils.getUserInformationIfAvailable {
            ZendeskUtils.promptUserForInformation(withName: withName) { success in
                guard success else {
                    DDLogInfo("No user information to create Zendesk identity with.")
                    completion(false)
                    return
                }

                ZendeskUtils.createZendeskIdentity { success in
                    guard success else {
                        DDLogInfo("Creating Zendesk identity failed.")
                        completion(false)
                        return
                    }
                    DDLogDebug("Using information from prompt for Zendesk identity.")
                    ZendeskUtils.sharedInstance.haveUserIdentity = true
                    completion(true)
                    return
                }
            }
        }
    }

    static func getUserInformationIfAvailable(completion: @escaping () -> ()) {

        /*
         Steps to selecting which account to use:
         1. If there is a WordPress.com account, use that.
         2. If not, use selected site.
        */

        let context = ContextManager.sharedInstance().mainContext

        // 1. Check for WP account
        let accountService = AccountService(managedObjectContext: context)
        if let defaultAccount = accountService.defaultWordPressComAccount() {
            DDLogDebug("Zendesk - Using defaultAccount for suggested identity.")
            getUserInformationFrom(wpAccount: defaultAccount)
            completion()
            return
        }

        // 2. Use information from selected site.
        let blogService = BlogService(managedObjectContext: context)

        guard let blog = blogService.lastUsedBlog() else {
            // We have no user information.
            completion()
            return
        }

        // 2a. Jetpack site
        if let jetpackState = blog.jetpack, jetpackState.isConnected {
            DDLogDebug("Zendesk - Using Jetpack site for suggested identity.")
            getUserInformationFrom(jetpackState: jetpackState)
            completion()
            return

        }

        // 2b. self-hosted site
        ZendeskUtils.getUserInformationFrom(blog: blog) {
            DDLogDebug("Zendesk - Using self-hosted for suggested identity.")
            completion()
            return
        }
    }

    static func createZendeskIdentity(completion: @escaping (Bool) -> Void) {

        guard let userEmail = ZendeskUtils.sharedInstance.userEmail else {
            DDLogInfo("No user email to create Zendesk identity with.")
            ZDKConfig.instance().userIdentity = nil
            completion(false)
            return
        }

        let zendeskIdentity = ZDKAnonymousIdentity()
        zendeskIdentity.email = userEmail
        zendeskIdentity.name = ZendeskUtils.sharedInstance.userName
        ZDKConfig.instance().userIdentity = zendeskIdentity
        DDLogDebug("Zendesk identity created with email '\(zendeskIdentity.email ?? "")' and name '\(zendeskIdentity.name ?? "")'.")
        registerDeviceIfNeeded()
        completion(true)
    }

    static func registerDeviceIfNeeded() {

        guard let deviceID = ZendeskUtils.sharedInstance.deviceID else {
            return
        }

        ZDKConfig.instance().enablePush(withDeviceID: deviceID) { pushResponse, error in
            if let error = error {
                DDLogInfo("Zendesk couldn't register device: \(deviceID). Error: \(error)")
            } else {
                ZendeskUtils.sharedInstance.deviceID = nil
                DDLogDebug("Zendesk successfully registered device: \(deviceID)")
            }
        }
    }

    func createRequest() {

        ZDKRequests.configure { (account, requestCreationConfig) in

            guard let requestCreationConfig = requestCreationConfig else {
                DDLogInfo("Zendesk requestCreationConfig creation failed.")
                return
            }

            // Set Zendesk ticket form to use
            ZDKConfig.instance().ticketFormId = TicketFieldIDs.form as NSNumber

            // Set form field values
            var ticketFields = [ZDKCustomField]()
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.appVersion as NSNumber, andValue: ZendeskUtils.appVersion))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.allBlogs as NSNumber, andValue: ZendeskUtils.getBlogInformation()))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.deviceFreeSpace as NSNumber, andValue: ZendeskUtils.getDeviceFreeSpace()))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.networkInformation as NSNumber, andValue: ZendeskUtils.getNetworkInformation()))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.logs as NSNumber, andValue: ZendeskUtils.getLogFile()))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.currentSite as NSNumber, andValue: ZendeskUtils.getCurrentSiteDescription()))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.sourcePlatform as NSNumber, andValue: ZendeskUtils.sourcePlatform))
            ticketFields.append(ZDKCustomField(fieldId: TicketFieldIDs.appLanguage as NSNumber, andValue: ZendeskUtils.appLanguage))
            ZDKConfig.instance().customTicketFields = ticketFields

            // Set tags
            requestCreationConfig.tags = ZendeskUtils.getTags()

            // Set the ticket subject
            requestCreationConfig.subject = Constants.ticketSubject
        }
    }

    // MARK: - View

    static func configureViewController(_ controller: UIViewController) {
        // If the controller is a UIViewController, set the modal display for iPad.
        // If the controller is a UINavigationController, do nothing as the ZD views will inherit from that.
        if !controller.isKind(of: UINavigationController.self) && WPDeviceIdentification.isiPad() {
            controller.modalPresentationStyle = .formSheet
            controller.modalTransitionStyle = .crossDissolve
        }
        presentInController = controller
    }

    static func setAppearance() {

        // Create a ZDKTheme object
        let theme = ZDKTheme.base()

        // Set color properties
        theme.primaryTextColor = WPStyleGuide.darkGrey()
        theme.secondaryTextColor = WPStyleGuide.darkGrey()
        theme.primaryBackgroundColor = UIColor.white
        theme.secondaryBackgroundColor = WPStyleGuide.lightGrey()
        theme.emptyBackgroundColor = WPStyleGuide.greyLighten30()
        theme.metaTextColor = WPStyleGuide.greyDarken10()
        theme.separatorColor = WPStyleGuide.greyLighten20()
        theme.inputFieldTextColor = WPStyleGuide.darkGrey()
        theme.inputFieldBackgroundColor = WPStyleGuide.lightGrey()

        // Apply the Theme
        theme.apply()
    }

    // MARK: - Get User Information

    static func getUserInformationFrom(jetpackState: JetpackState) {
        ZendeskUtils.sharedInstance.userName = jetpackState.connectedUsername
        ZendeskUtils.sharedInstance.userEmail = jetpackState.connectedEmail
    }

    static func getUserInformationFrom(blog: Blog, completion: @escaping () -> ()) {

        ZendeskUtils.sharedInstance.userName = blog.username

        // Get email address from remote profile
        guard let username = blog.username,
            let password = blog.password,
            let xmlrpc = blog.xmlrpc,
            let service = UsersService(username: username, password: password, xmlrpc: xmlrpc) else {
                return
        }

        service.fetchProfile { userProfile in
            guard let userProfile = userProfile else {
                completion()
                return
            }
            ZendeskUtils.sharedInstance.userEmail = userProfile.email
            completion()
        }
    }

    static func getUserInformationFrom(wpAccount: WPAccount) {

        guard let api = wpAccount.wordPressComRestApi else {
            DDLogInfo("Zendesk: No wordPressComRestApi.")
            return
        }

        let service = AccountSettingsService(userID: wpAccount.userID.intValue, api: api)

        guard let accountSettings = service.settings else {
            DDLogInfo("Zendesk: No accountSettings.")
            return
        }

        ZendeskUtils.sharedInstance.userEmail = wpAccount.email
        ZendeskUtils.sharedInstance.userName = wpAccount.username
        if accountSettings.firstName.count > 0 || accountSettings.lastName.count > 0 {
            ZendeskUtils.sharedInstance.userName = (accountSettings.firstName + " " + accountSettings.lastName).trim()
        }
    }

    // MARK: - User Defaults

    static func saveUserProfile() {
        var userProfile = [String: String]()
        userProfile[Constants.profileEmailKey] = ZendeskUtils.sharedInstance.userEmail
        userProfile[Constants.profileNameKey] = ZendeskUtils.sharedInstance.userName
        DDLogDebug("Zendesk - saving profile to User Defaults: \(userProfile)")
        UserDefaults.standard.set(userProfile, forKey: Constants.zendeskProfileUDKey)
        UserDefaults.standard.synchronize()
    }

    static func getUserProfile() -> Bool {
        guard let userProfile = UserDefaults.standard.dictionary(forKey: Constants.zendeskProfileUDKey) else {
            return false
        }
        DDLogDebug("Zendesk - read profile from User Defaults: \(userProfile)")
        ZendeskUtils.sharedInstance.userEmail = userProfile.valueAsString(forKey: Constants.profileEmailKey)
        ZendeskUtils.sharedInstance.userName = userProfile.valueAsString(forKey: Constants.profileNameKey)
        return true
    }

    static func saveUnreadCount() {
        UserDefaults.standard.set(unreadNotificationsCount, forKey: Constants.userDefaultsZendeskUnreadNotifications)
        UserDefaults.standard.synchronize()
    }

    // MARK: - Data Helpers

    static func getDeviceFreeSpace() -> String {

        guard let resourceValues = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityKey]),
            let capacityBytes = resourceValues.volumeAvailableCapacity else {
                return Constants.unknownValue
        }

        // format string using human readable units. ex: 1.5 GB
        // Since ByteCountFormatter.string translates the string and has no locale setting,
        // do the byte conversion manually so the Free Space is in English.
        let sizeAbbreviations = ["bytes", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
        var sizeAbbreviationsIndex = 0
        var capacity = Double(capacityBytes)

        while capacity > 1024 {
            capacity /= 1024
            sizeAbbreviationsIndex += 1
        }

        let formattedCapacity = String(format: "%4.2f", capacity)
        let sizeAbbreviation = sizeAbbreviations[sizeAbbreviationsIndex]
        return "\(formattedCapacity) \(sizeAbbreviation)"
    }

    static func getLogFile() -> String {

        guard let appDelegate = UIApplication.shared.delegate as? WordPressAppDelegate,
            let fileLogger = appDelegate.logger.fileLogger,
            let logFileInformation = fileLogger.logFileManager.sortedLogFileInfos.first,
            let logData = try? Data(contentsOf: URL(fileURLWithPath: logFileInformation.filePath)),
            let logText = String(data: logData, encoding: .utf8) else {
                return ""
        }

        return logText
    }

    static func getCurrentSiteDescription() -> String {
        let blogService = BlogService(managedObjectContext: ContextManager.sharedInstance().mainContext)

        guard let blog = blogService.lastUsedBlog() else {
            return Constants.noValue
        }

        let url = blog.url ?? Constants.unknownValue
        return "\(url) (\(blog.stateDescription()))"
    }

    static func getBlogInformation() -> String {

        let blogService = BlogService(managedObjectContext: ContextManager.sharedInstance().mainContext)

        guard let allBlogs = blogService.blogsForAllAccounts() as? [Blog], allBlogs.count > 0 else {
            return Constants.noValue
        }

        return (allBlogs.map { $0.supportDescription() }).joined(separator: Constants.blogSeperator)
    }

    static func getTags() -> [String] {

        let context = ContextManager.sharedInstance().mainContext
        let blogService = BlogService(managedObjectContext: context)

        // If there are no sites, then the user has an empty WP account.
        guard let allBlogs = blogService.blogsForAllAccounts() as? [Blog], allBlogs.count > 0 else {
            return [Constants.wpComTag]
        }

        // Get all unique site plans
        var tags = allBlogs.compactMap { $0.planTitle }.unique

        // If any of the sites have jetpack installed, add jetpack tag.
        let jetpackBlog = allBlogs.first { $0.jetpack?.isInstalled == true }
        if let _ = jetpackBlog {
            tags.append(Constants.jetpackTag)
        }

        // If there is a WP account, add wpcom tag.
        let accountService = AccountService(managedObjectContext: context)
        if let _ = accountService.defaultWordPressComAccount() {
            tags.append(Constants.wpComTag)
        }

        // Add sourceTag
        if let sourceTagOrigin = ZendeskUtils.sharedInstance.sourceTag?.origin {
            tags.append(sourceTagOrigin)
        }

        // Add platformTag
        tags.append(Constants.platformTag)

        return tags
    }

    static func getNetworkInformation() -> String {

        var networkInformation = [String]()

        let reachibilityStatus = ZDKReachability.forInternetConnection().currentReachabilityStatus()

        let networkType: String = {
            switch reachibilityStatus {
            case .reachableViaWiFi:
                return Constants.networkWiFi
            case .reachableViaWWAN:
                return Constants.networkWWAN
            default:
                return Constants.unknownValue
            }
        }()

        let networkCarrier = CTTelephonyNetworkInfo().subscriberCellularProvider
        let carrierName = networkCarrier?.carrierName ?? Constants.unknownValue
        let carrierCountryCode = networkCarrier?.isoCountryCode ?? Constants.unknownValue

        networkInformation.append("\(Constants.networkTypeLabel) \(networkType)")
        networkInformation.append("\(Constants.networkCarrierLabel) \(carrierName)")
        networkInformation.append("\(Constants.networkCountryCodeLabel) \(carrierCountryCode)")

        return networkInformation.joined(separator: "\n")
    }

    // MARK: - Push Notification Helpers

    static func postNotificationReceived() {
        // Updating unread indicators should trigger UI updates, so send notification in main thread.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ZendeskPushNotificationReceivedNotification, object: nil)
        }
    }

    static func postNotificationRead() {
        // Updating unread indicators should trigger UI updates, so send notification in main thread.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ZendeskPushNotificationClearedNotification, object: nil)
        }
    }

    @objc static func ticketViewed(_ notification: Foundation.Notification) {
        pushNotificationRead()
    }

    // MARK: - User Information Prompt

    static func promptUserForInformation(withName: Bool, completion: @escaping (Bool) -> Void) {

        let alertController = UIAlertController(title: nil,
                                                message: nil,
                                                preferredStyle: .alert)

        let alertMessage = withName ? LocalizedText.alertMessageWithName : LocalizedText.alertMessage
        alertController.setValue(NSAttributedString(string: alertMessage, attributes: [.font: WPStyleGuide.subtitleFont()]),
                                 forKey: "attributedMessage")

        // Cancel Action
        alertController.addCancelActionWithTitle(LocalizedText.alertCancel) { (_) in
            completion(false)
            return
        }

        // Submit Action
        let submitAction = alertController.addDefaultActionWithTitle(LocalizedText.alertSubmit) { [weak alertController] (_) in
            guard let email = alertController?.textFields?.first?.text else {
                completion(false)
                return
            }

            ZendeskUtils.sharedInstance.userEmail = email

            if withName {
                ZendeskUtils.sharedInstance.userName = alertController?.textFields?.last?.text
            }

            saveUserProfile()
            completion(true)
            return
        }

        // Enable Submit based on email validity.
        let email = ZendeskUtils.sharedInstance.userEmail ?? ""
        submitAction.isEnabled = EmailFormatValidator.validate(string: email)

        // Make Submit button bold.
        alertController.preferredAction = submitAction

        // Email Text Field
        alertController.addTextField(configurationHandler: { textField in
            textField.clearButtonMode = .always
            textField.placeholder = LocalizedText.emailPlaceholder
            textField.text = ZendeskUtils.sharedInstance.userEmail

            textField.addTarget(self,
                                action: #selector(emailTextFieldDidChange),
                                for: UIControlEvents.editingChanged)
        })

        // Name Text Field
        if withName {
            alertController.addTextField { textField in
                textField.clearButtonMode = .always
                textField.placeholder = LocalizedText.namePlaceholder
                textField.text = ZendeskUtils.sharedInstance.userName
                textField.delegate = ZendeskUtils.sharedInstance
                ZendeskUtils.sharedInstance.alertNameField = textField
            }
        }

        // Show alert
        presentInController?.present(alertController, animated: true, completion: nil)
    }

    @objc static func emailTextFieldDidChange(_ textField: UITextField) {
        guard let alertController = presentInController?.presentedViewController as? UIAlertController,
            let email = alertController.textFields?.first?.text,
            let submitAction = alertController.actions.last else {
                return
        }

        submitAction.isEnabled = EmailFormatValidator.validate(string: email)
        updateNameFieldForEmail(email)
    }

    static func updateNameFieldForEmail(_ email: String) {
        guard let alertController = presentInController?.presentedViewController as? UIAlertController,
            let nameField = alertController.textFields?.last else {
                return
        }

        guard !email.isEmpty else {
            return
        }

        // If we don't already have the user's name, generate it from the email.
        if ZendeskUtils.sharedInstance.userName == nil {
            nameField.text = generateDisplayName(from: email)
        }
    }

    static func generateDisplayName(from rawEmail: String) -> String {

        // Generate Name, using the same format as Signup.

        // step 1: lower case
        let email = rawEmail.lowercased()
        // step 2: remove the @ and everything after
        let localPart = email.split(separator: "@")[0]
        // step 3: remove all non-alpha characters
        let localCleaned = localPart.replacingOccurrences(of: "[^A-Za-z/.]", with: "", options: .regularExpression)
        // step 4: turn periods into spaces
        let nameLowercased = localCleaned.replacingOccurrences(of: ".", with: " ")
        // step 5: capitalize
        let autoDisplayName = nameLowercased.capitalized

        return autoDisplayName
    }

    // MARK: - Zendesk Notifications

    static func observeZendeskNotifications() {
        // Ticket Attachments
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_UploadAttachmentSuccess), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_UploadAttachmentError), object: nil)

        // New Ticket Creation
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_RequestSubmissionSuccess), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_RequestSubmissionError), object: nil)

        // Ticket Reply
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_CommentSubmissionSuccess), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_CommentSubmissionError), object: nil)

        // View Ticket List
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_RequestsError), object: nil)

        // View Individual Ticket
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_CommentListSuccess), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZDKAPI_CommentListError), object: nil)

        // Help Center
        NotificationCenter.default.addObserver(self, selector: #selector(ZendeskUtils.zendeskNotification(_:)),
                                               name: NSNotification.Name(rawValue: ZD_HC_SearchSuccess), object: nil)
    }

    @objc static func zendeskNotification(_ notification: Foundation.Notification) {
        switch notification.name.rawValue {
        case ZDKAPI_RequestSubmissionSuccess:
            WPAnalytics.track(.supportNewRequestCreated)
        case ZDKAPI_RequestSubmissionError:
            WPAnalytics.track(.supportNewRequestFailed)
        case ZDKAPI_UploadAttachmentSuccess:
            WPAnalytics.track(.supportNewRequestFileAttached)
        case ZDKAPI_UploadAttachmentError:
            WPAnalytics.track(.supportNewRequestFileAttachmentFailed)
        case ZDKAPI_CommentSubmissionSuccess:
            WPAnalytics.track(.supportTicketUserReplied)
        case ZDKAPI_CommentSubmissionError:
            WPAnalytics.track(.supportTicketUserReplyFailed)
        case ZDKAPI_RequestsError:
            WPAnalytics.track(.supportTicketListViewFailed)
        case ZDKAPI_CommentListSuccess:
            WPAnalytics.track(.supportTicketUserViewed)
        case ZDKAPI_CommentListError:
            WPAnalytics.track(.supportTicketViewFailed)
        case ZD_HC_SearchSuccess:
            WPAnalytics.track(.supportHelpCenterUserSearched)
        default:
            break
        }
    }

    // MARK: - Constants

    struct Constants {
        static let unknownValue = "unknown"
        static let noValue = "none"
        static let mobileCategoryID = "360000041586"
        static let articleLabel = "iOS"
        static let platformTag = "iOS"
        static let ticketSubject = NSLocalizedString("WordPress for iOS Support", comment: "Subject of new Zendesk ticket.")
        static let blogSeperator = "\n----------\n"
        static let jetpackTag = "jetpack"
        static let wpComTag = "wpcom"
        static let networkWiFi = "WiFi"
        static let networkWWAN = "Mobile"
        static let networkTypeLabel = "Network Type:"
        static let networkCarrierLabel = "Carrier:"
        static let networkCountryCodeLabel = "Country Code:"
        static let zendeskProfileUDKey = "wp_zendesk_profile"
        static let profileEmailKey = "email"
        static let profileNameKey = "name"
        static let userDefaultsZendeskUnreadNotifications = "wp_zendesk_unread_notifications"
        static let nameFieldCharacterLimit = 50
    }

    // Zendesk expects these as NSNumber. However, they are defined as UInt64 to satisfy 32-bit devices (ex: iPhone 5).
    // Which means they then have to be converted to NSNumber when sending to Zendesk.
    struct TicketFieldIDs {
        static let form: UInt64 = 360000010286
        static let appVersion: UInt64 = 360000086866
        static let allBlogs: UInt64 = 360000087183
        static let deviceFreeSpace: UInt64 = 360000089123
        static let networkInformation: UInt64 = 360000086966
        static let logs: UInt64 = 22871957
        static let currentSite: UInt64 = 360000103103
        static let sourcePlatform: UInt64 = 360009311651
        static let appLanguage: UInt64 = 360008583691
    }

    struct LocalizedText {
        static let alertMessageWithName = NSLocalizedString("To continue please enter your email address and name.", comment: "Instructions for alert asking for email and name.")
        static let alertMessage = NSLocalizedString("Please enter your email address.", comment: "Instructions for alert asking for email.")
        static let alertSubmit = NSLocalizedString("OK", comment: "Submit button on prompt for user information.")
        static let alertCancel = NSLocalizedString("Cancel", comment: "Cancel prompt for user information.")
        static let emailPlaceholder = NSLocalizedString("Email", comment: "Email address text field placeholder")
        static let namePlaceholder = NSLocalizedString("Name", comment: "Name text field placeholder")
    }

}

// MARK: - ZDKHelpCenterConversationsUIDelegate

extension ZendeskUtils: ZDKHelpCenterConversationsUIDelegate {

    func navBarConversationsUIType() -> ZDKNavBarConversationsUIType {
        // When ZDKContactUsVisibility is on, use the default right nav bar label.
        return .localizedLabel
    }

    func active() -> ZDKContactUsVisibility {
        // If we don't have the user's information, disable 'Contact Us' via the Help Center and Article view.
        if !ZendeskUtils.sharedInstance.haveUserIdentity {
            return .off
        }

        return .articleListAndArticle
    }

    func conversationsBarButtonImage() -> UIImage! {
        // Nothing to do here, but this method is required for ZDKHelpCenterConversationsUIDelegate.
        return UIImage()
    }

}

// MARK: - UITextFieldDelegate

extension ZendeskUtils: UITextFieldDelegate {

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard textField == ZendeskUtils.sharedInstance.alertNameField,
        let text = textField.text else {
            return true
        }

        let newLength = text.count + string.count - range.length
        return newLength <= Constants.nameFieldCharacterLimit
    }

}
