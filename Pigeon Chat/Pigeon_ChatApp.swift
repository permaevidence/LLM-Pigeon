//
//  Pigeon_ChatApp.swift
//  Pigeon Chat
//
//  Created by matteo ianni on 06/06/25.
//

//  Pigeon_ChatApp.swift
//  Private AI Chat – iOS client
//  Updated June 2025 – Fixed duplicate push registration and other improvements

import SwiftUI
import CloudKit
import UserNotifications
import Combine
import MarkdownUI

// MARK: - Shared Models (Ensure these are identical to macOS app's models)
struct Message: Identifiable, Codable {
    let id: UUID // Changed from 'let id = UUID()' to ensure it's decoded if present
    let role: String // "user" | "assistant"
    let content: String
    let timestamp: Date

    // Custom initializer for programmatic creation, ensuring an ID is always set
    init(id: UUID = UUID(), role: String, content: String, timestamp: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        // Optional: print("[Message Programmatic Init] ID: \(self.id.uuidString.prefix(8))")
    }

    // Explicit Codable conformance to be certain about id handling
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
    }

    // Decoder: If 'id' is missing in JSON, generate a new one.
    // This was likely the behavior with 'let id = UUID()', making IDs unstable if not in JSON.
    // By making 'id' non-optional and decoding it, we force it to be in the JSON.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try to decode 'id'. If it's not in the JSON, this will fail, which is good
        // because it means our JSONEncoder isn't saving it.
        // If it IS in the JSON, it will be used.
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        // Optional: print("[Message Decoded] ID: \(self.id.uuidString.prefix(8)) from JSON")
    }

    // Encoder: Ensure 'id' is always encoded.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.content, forKey: .content)
        try container.encode(self.timestamp, forKey: .timestamp)
    }
}

extension Message {
    /// Returns the message content with <think></think> tags and their contents removed
    var displayContent: String {
        // Regular expression pattern to match <think>...</think> tags and their content
        // This handles both single-line and multi-line content within the tags
        let pattern = #"<think>[\s\S]*?</think>"#
        
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(location: 0, length: content.utf16.count)
            
            // Replace all occurrences with an empty string
            let cleanedContent = regex.stringByReplacingMatches(
                in: content,
                options: [],
                range: range,
                withTemplate: ""
            )
            
            // Trim any extra whitespace that might be left over
            return cleanedContent.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // If regex fails for any reason, return original content
            print("[Message] Error creating regex for cleaning content: \(error)")
            return content
        }
    }
}

struct Conversation: Codable, Identifiable {
    var id: String
    var messages: [Message]
    var lastUpdated: Date
}

// MARK: - CloudKit Manager
@MainActor
final class CloudKitManager: NSObject, ObservableObject {

    static let shared = CloudKitManager()
    private override init() {
        container = CKContainer(identifier: Self.containerID)
        privateDB = container.privateCloudDatabase
        super.init()
        Task {
            await refreshAccountStatus() // Refresh status early
            await ensureSubscriptionExists() // Setup subscription
            await loadConversations()    // Load initial data
        }
    }

    // MARK: Public @Published state
    @Published var currentConversation: Conversation?
    @Published var conversations: [Conversation] = []
    @Published var isWaitingForResponse = false
    @Published var errorMessage: String?
    @Published var connectionStatus: String = "Checking…"
    @Published var lastSync: Date?

    // MARK: Private
    private static let containerID = "iCloud.com.pigeonchat.pigeonchat" // Ensure this matches your container
    private let iOSConversationSubscriptionID = "iOSConversationNeedsResponseUpdates_v2" // Unique & versioned

    private let container: CKContainer
    let privateDB: CKDatabase // Made internal for potential AppDelegate direct use if needed, but shared is better
    private var pollTask: Task<Void, Never>? = nil
    private var backOff: TimeInterval = 1.0

    // MARK: Notification Setup (called from AppDelegate)
    func setupNotifications() async {
        UNUserNotificationCenter.current().delegate = self // Self is already the delegate via AppDelegate
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge, .sound, .alert])
            if granted {
                print("[iOS] Notification permission granted.")
                await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
            } else {
                print("[iOS] Notification permission denied.")
            }
        } catch {
            print("[iOS] Error requesting notification authorization: \(error.localizedDescription)")
        }
    }

    // MARK: Subscription Setup
    private func ensureSubscriptionExists() async {
        do {
            // Try to fetch the subscription.
            // This method throws CKError.unknownItem if the subscription does not exist.
            let existingSubscription = try await privateDB.subscription(for: iOSConversationSubscriptionID)
            print("[iOS] Subscription '\(iOSConversationSubscriptionID)' already exists. Details: \(existingSubscription)")
            // If we reach here, the subscription exists. No need to create.
            return
        } catch let error as CKError where error.code == .unknownItem {
            // Subscription does not exist, proceed to create it.
            print("[iOS] Subscription '\(iOSConversationSubscriptionID)' not found (CKError.unknownItem). Will attempt to create.")
            // Fall through to creation logic outside this do-catch block.
        } catch let error as CKError {
            // Some other CloudKit error occurred during the fetch.
            // It's not safe to try and create it now.
            let errorCode = error.errorCode
            let errorDescription = error.localizedDescription
            let fullError = "[iOS] CKError checking for subscription '\(iOSConversationSubscriptionID)': \(errorDescription) (Code: \(errorCode)). Full Details: \(error). Will NOT attempt to create."
            print(fullError)
            await MainActor.run {
                 self.errorMessage = "Subscription Check Error (iOS): \(errorDescription) (Code: \(errorCode))"
            }
            return // Do not proceed to creation
        } catch {
            // Some other non-CloudKit error.
            let fullError = "[iOS] An unexpected error occurred while checking for subscription '\(iOSConversationSubscriptionID)': \(error.localizedDescription). Full Details: \(error). Will NOT attempt to create."
            print(fullError)
            await MainActor.run {
                self.errorMessage = "Subscription Check Error (iOS): Unexpected. Will NOT attempt to create."
            }
            return // Do not proceed to creation
        }

        // If we reached here, it means .unknownItem was caught, so create the subscription.
        print("[iOS] Attempting to create subscription '\(iOSConversationSubscriptionID)' because it was not found.")
        let predicate = NSPredicate(format: "needsResponse == 0") // iOS listens for records processed by Mac (needsResponse = 0)
        let subscription = CKQuerySubscription(recordType: "Conversation",
                                               predicate: predicate,
                                               subscriptionID: iOSConversationSubscriptionID,
                                               options: [.firesOnRecordUpdate]) // Only when an existing record is updated to match

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true // For silent push
        // For debugging, you can enable alerts:
        // notificationInfo.alertBody = "iOS: Conversation updated by server!"
        // notificationInfo.shouldBadge = true
        subscription.notificationInfo = notificationInfo

        do {
            let savedSubscription = try await privateDB.save(subscription)
            print("[iOS] Successfully saved new subscription '\(savedSubscription.subscriptionID)'. Type: \(type(of: savedSubscription))")
        } catch let error as CKError {
            let errorCode = error.errorCode
            let errorDescription = error.localizedDescription
            // This is where the original error in the screenshot is likely coming from.
            let fullError = "[iOS] Failed to save subscription '\(iOSConversationSubscriptionID)': \(errorDescription) (Code: \(errorCode)). Full Details: \(error)"
            print(fullError)
            await MainActor.run {
                 // Use a more specific message that matches the screenshot if possible, or this detailed one.
                 self.errorMessage = "Subscription Error (iOS): Error saving record subscription with id \(iOSConversationSubscriptionID) to server: \(errorDescription) (Code: \(errorCode))"
            }
        } catch {
            let fullError = "[iOS] An unexpected error occurred while saving subscription '\(iOSConversationSubscriptionID)': \(error.localizedDescription). Full Details: \(error)"
            print(fullError)
            await MainActor.run {
                self.errorMessage = "Subscription Error (iOS): Unexpected error saving subscription."
            }
        }
    }

    private func refreshAccountStatus() async {
        do {
            let status = try await container.accountStatus()
            var newStatus = ""
            switch status {
            case .available: newStatus = "Connected"
            case .noAccount: newStatus = "No iCloud account"
            case .restricted: newStatus = "iCloud account restricted"
            case .couldNotDetermine: newStatus = "Could not determine iCloud status"
            @unknown default: newStatus = "Unknown iCloud status"
            }
            connectionStatus = newStatus
            print("[iOS] iCloud Account Status: \(newStatus)")
        } catch {
            connectionStatus = "Error checking status"
            let errorMsg = "[iOS] Error refreshing account status: \(error.localizedDescription)"
            print(errorMsg)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Conversation CRUD
    func startNewConversation() {
        let convID = UUID().uuidString
        print("[iOS] Starting new conversation with ID: \(convID.prefix(8))")
        let conv = Conversation(id: convID, messages: [], lastUpdated: .now)
        currentConversation = conv
        // OLD way:
        // if !conversations.contains(where: { $0.id == conv.id }) {
        //     conversations.insert(conv, at: 0)
        // }
        // NEW way: Use upsertLocally to handle insertion and sorting
        upsertLocally(conv) // <-- MODIFIED
        Task { await saveConversation(needsResponse: false) }
    }

    func sendMessage(_ text: String) {
        guard var conv = currentConversation else {
            print("[iOS] Error: sendMessage called with no currentConversation.")
            return
        }
        print("[iOS] Sending message in conversation \(conv.id.prefix(8))")
        let userMsg = Message(role: "user", content: text, timestamp: .now)
        conv.messages.append(userMsg)
        conv.lastUpdated = .now
        currentConversation = conv
        upsertLocally(conv)
        isWaitingForResponse = true
        Task { await saveConversation(needsResponse: true) }
        startPolling() // Fallback polling
    }

    func selectConversation(_ conv: Conversation) {
        print("[iOS] Selecting conversation \(conv.id.prefix(8))")
        currentConversation = conv
        Task { await fetchConversation(id: conv.id) }
    }

    func deleteConversation(_ conv: Conversation) {
        print("[iOS] Deleting conversation \(conv.id.prefix(8))")
        Task {
            do {
                try await privateDB.deleteRecord(withID: CKRecord.ID(recordName: conv.id))
                conversations.removeAll { $0.id == conv.id }
                if currentConversation?.id == conv.id {
                    currentConversation = conversations.first
                    print("[iOS] Deleted current conversation, selected new current: \(currentConversation?.id.prefix(8) ?? "None")")
                }
            } catch {
                let errorMsg = "[iOS] Error deleting conversation \(conv.id.prefix(8)): \(error.localizedDescription)"
                print(errorMsg)
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: CloudKit helpers
    private func loadConversations() async {
        print("[iOS] Loading conversations...")
        let query = CKQuery(recordType: "Conversation", predicate: NSPredicate(value: true))
        // Sort by the 'lastUpdated' field we store on the CKRecord, descending (newest first)
        query.sortDescriptors = [NSSortDescriptor(key: "lastUpdated", ascending: false)] // <-- MODIFIED/UNCOMMENTED

        do {
            let (matchResults, _) = try await privateDB.records(matching: query)
            var loadedConversations: [Conversation] = []
            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    if let data = record["conversationData"] as? Data,
                       let c = try? JSONDecoder().decode(Conversation.self, from: data) {
                        loadedConversations.append(c)
                    } else {
                        print("[iOS] Failed to decode conversationData for record: \(record.recordID.recordName)")
                    }
                case .failure(let error):
                    print("[iOS] Error fetching a record in loadConversations: \(error.localizedDescription)")
                }
            }
            // Now that CloudKit sorts, 'loadedConversations' will be in order.
            // If you wanted client-side sort instead, you'd do:
            // loadedConversations.sort { $0.lastUpdated > $1.lastUpdated }
            conversations = loadedConversations
            if currentConversation == nil || !conversations.contains(where: { $0.id == currentConversation?.id }) {
                currentConversation = conversations.first // This will be the most recent if list is sorted
            }
            lastSync = .now
            print("[iOS] Loaded \(conversations.count) conversations. Current: \(currentConversation?.id.prefix(8) ?? "None")")
        } catch {
            let errorMsg = "[iOS] Error loading conversations: \(error.localizedDescription)"
            print(errorMsg)
            errorMessage = error.localizedDescription
        }
    }

    private func fetchConversation(id: String) async {
        print("[iOS] Fetching conversation \(id.prefix(8))...")
        
        do {
            let recordID = CKRecord.ID(recordName: id)
            let serverRecord = try await privateDB.record(for: recordID)
            guard let data = serverRecord["conversationData"] as? Data,
                  let fetchedConvData = try? JSONDecoder().decode(Conversation.self, from: data) else {
                print("[iOS] Failed to decode conversationData for fetched record: \(id.prefix(8))")
                // Consider what to do with isWaitingForResponse here. If fetch fails, maybe don't change it.
                return
            }

            var conversationToUpdate: Conversation
            var newMessagesMerged = false

            if var localCurrentConv = self.currentConversation, localCurrentConv.id == fetchedConvData.id {
                // We have a local version, try to merge
                conversationToUpdate = localCurrentConv
                
                var existingMessageIDs = Set(conversationToUpdate.messages.map { $0.id })
                var messagesToAdd: [Message] = []

                for serverMessage in fetchedConvData.messages {
                    if !existingMessageIDs.contains(serverMessage.id) {
                        messagesToAdd.append(serverMessage)
                        existingMessageIDs.insert(serverMessage.id) // Add to set to handle duplicates in fetchedConvData (though unlikely)
                        newMessagesMerged = true
                        if serverMessage.role == "assistant" {
                            print("[iOS] Merging new assistant message ID: \(serverMessage.id.uuidString.prefix(8)) for convo \(id.prefix(8))")
                        } else {
                            print("[iOS] Merging new user message ID: \(serverMessage.id.uuidString.prefix(8)) (likely from another device or confirming own) for convo \(id.prefix(8))")
                        }
                    }
                }

                if newMessagesMerged {
                    conversationToUpdate.messages.append(contentsOf: messagesToAdd)
                    // Ensure messages are sorted by timestamp after merge
                    conversationToUpdate.messages.sort { $0.timestamp < $1.timestamp }
                }
                // Always update lastUpdated from the server's version as it's the source of truth for this fetch
                conversationToUpdate.lastUpdated = fetchedConvData.lastUpdated

            } else {
                // No local current conversation with this ID, or it's a different one. Use the fetched one directly.
                conversationToUpdate = fetchedConvData
                newMessagesMerged = true // Considered merged as it's new to local state
            }
            
            // Only assign if there were changes or it's a new assignment
            if newMessagesMerged || self.currentConversation?.id != conversationToUpdate.id || self.currentConversation?.lastUpdated != conversationToUpdate.lastUpdated {
                self.currentConversation = conversationToUpdate
                upsertLocally(conversationToUpdate) // Update the list of conversations as well
                print("[iOS] Updated currentConversation for \(id.prefix(8)). Total messages: \(conversationToUpdate.messages.count)")
            }


            // Update UI state based on the potentially updated currentConversation
            if let lastMessage = self.currentConversation?.messages.last, self.currentConversation?.id == id {
                if lastMessage.role == "assistant" {
                    print("[iOS] Fetched conversation \(id.prefix(8)) now has assistant response. Stopping poll.")
                    stopPolling() // This also sets isWaitingForResponse = false
                } else if lastMessage.role == "user" {
                     print("[iOS] Fetched conversation \(id.prefix(8)), last message is user. Still waiting. Ensuring poll is active if needed.")
                     if !isWaitingForResponse { isWaitingForResponse = true } // Make sure we are in waiting state
                     if pollTask == nil && isWaitingForResponse { startPolling() } // Start polling if not already and still waiting
                } else { // No messages or unexpected state for the current conversation
                    if isWaitingForResponse { isWaitingForResponse = false }
                }
            } else if self.currentConversation?.id != id {
                // Fetched a conversation that is not the current one, don't change global waiting state based on it.
                print("[iOS] Fetched non-current conversation \(id.prefix(8)). Global waiting state unchanged by this specific fetch.")
            } else { // Current conversation is nil or has no messages
                if isWaitingForResponse { isWaitingForResponse = false }
            }

            lastSync = .now

        } catch let error as CKError where error.code == .unknownItem {
            print("[iOS] Fetch conversation \(id.prefix(8)) failed: Record not found.")
            errorMessage = "Conversation \(id.prefix(8)) not found."
            // If the *current* conversation is not found, we should stop waiting for it.
            if currentConversation?.id == id {
                if isWaitingForResponse { isWaitingForResponse = false }
                // Optionally clear currentConversation or remove from list
                // conversations.removeAll { $0.id == id }
                // if self.currentConversation?.id == id { self.currentConversation = conversations.first }
            }
        } catch {
            let errorMsg = "[iOS] Error fetching conversation \(id.prefix(8)): \(error.localizedDescription)"
            print(errorMsg)
            errorMessage = error.localizedDescription
            // If fetch for current conversation fails, stop waiting for its response.
            if currentConversation?.id == id {
                if isWaitingForResponse { isWaitingForResponse = false }
            }
        }
    }

    private func saveConversation(needsResponse: Bool) async {
        guard let conv = currentConversation else {
            print("[iOS] Error: saveConversation called with no currentConversation.")
            return
        }
        print("[iOS] Saving conversation \(conv.id.prefix(8)), needsResponse: \(needsResponse)")
        do {
            let recordID = CKRecord.ID(recordName: conv.id)
            // Try to fetch existing record to get its changeTag for optimistic locking,
            // or create a new one if it doesn't exist.
            let recordToSave: CKRecord
            do {
                recordToSave = try await privateDB.record(for: recordID)
                 print("[iOS] Found existing record \(conv.id.prefix(8)) to update.")
            } catch let error as CKError where error.code == .unknownItem {
                print("[iOS] Record \(conv.id.prefix(8)) not found, creating new one for save.")
                recordToSave = CKRecord(recordType: "Conversation", recordID: recordID)
            }
            // If fetching failed for other reasons, this will re-throw

            let data = try JSONEncoder().encode(conv)
            recordToSave["conversationData"] = data as CKRecordValue
            recordToSave["lastUpdated"] = conv.lastUpdated as CKRecordValue // CloudKit uses modifiedTimestamp automatically, but explicit can be useful
            recordToSave["needsResponse"] = (needsResponse ? 1 : 0) as CKRecordValue

            // Using modern concurrency for save
            let savedRecord = try await privateDB.save(recordToSave)
            print("[iOS] Successfully saved conversation \(savedRecord.recordID.recordName.prefix(8)) to CloudKit.")
            lastSync = .now
            // If this save was for the user sending a message, polling is already started.
            // If this save was for creating a new conversation, no polling needed yet.
        } catch let error as CKError {
            let errorMsg = "[iOS] CKError saving conversation \(conv.id.prefix(8)): \(error.localizedDescription) (Code: \(error.code.rawValue))"
            print(errorMsg)
            errorMessage = "Save Error: \(error.localizedDescription)"
        } catch {
            let errorMsg = "[iOS] Unexpected error saving conversation \(conv.id.prefix(8)): \(error.localizedDescription)"
            print(errorMsg)
            errorMessage = "Save Error: \(error.localizedDescription)"
        }
    }

    private func upsertLocally(_ conv: Conversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        } else {
            conversations.insert(conv, at: 0) // Inserts at top, sort will place it correctly
        }
        // This sort is crucial and correctly re-sorts the entire list by lastUpdated, newest first.
        conversations.sort { $0.lastUpdated > $1.lastUpdated }
    }

    // MARK: Exponential back-off polling fallback
    private func startPolling() {
        guard currentConversation != nil else {
            print("[iOS] Polling not started: no current conversation.")
            return
        }
        guard isWaitingForResponse else {
            print("[iOS] Polling not started: not waiting for response.")
            stopPolling() // Ensure any existing poll is stopped
            return
        }

        if pollTask != nil {
            print("[iOS] Polling already active for \(currentConversation?.id.prefix(8) ?? "N/A").")
            return
        }

        backOff = 1.0 // Reset backoff
        print("[iOS] Starting polling for \(currentConversation!.id.prefix(8)) with backoff \(backOff)s.")
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isWaitingForResponse {
                if let currentConvID = self.currentConversation?.id {
                    print("[iOS] Polling... fetching \(currentConvID.prefix(8)). Next poll in \(self.backOff)s.")
                    await self.fetchConversation(id: currentConvID)
                    // fetchConversation will call stopPolling if response is received
                } else {
                    print("[iOS] Polling: No current conversation ID. Stopping poll.")
                    self.stopPolling() // Should cancel the task
                    break
                }
                
                if Task.isCancelled || !self.isWaitingForResponse { break } // Check again after fetch
                
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.backOff * 1_000_000_000))
                } catch { // Catches CancellationError if task is cancelled during sleep
                    print("[iOS] Polling sleep cancelled.")
                    break
                }
                self.backOff = min(self.backOff * 1.5, 30) // 1, 1.5, 2.25, ... capped at 30s
            }
            print("[iOS] Polling task ended for \(self.currentConversation?.id.prefix(8) ?? "N/A"). Cancelled: \(Task.isCancelled), Waiting: \(self.isWaitingForResponse)")
            // Ensure pollTask is nilled out if loop finishes naturally or by cancellation
             if self.pollTask != nil { // Check if it's this specific task instance
                self.pollTask = nil
             }
        }
    }

    func stopPolling() { // Made internal for clarity, can be private
        if pollTask != nil {
            print("[iOS] Stopping polling for \(currentConversation?.id.prefix(8) ?? "N/A").")
            pollTask?.cancel()
            pollTask = nil
        }
        if isWaitingForResponse { // Only change if it was true
            isWaitingForResponse = false
        }
    }

    // MARK: Remote notification entry
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        print("[iOS] Received remote notification.")
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            print("[iOS] Failed to parse CKNotification from userInfo.")
            return
        }

        guard notification.subscriptionID == iOSConversationSubscriptionID,
              let queryNotification = notification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            print("[iOS] Notification is not for our subscription or not a query notification with recordID. ID: \(notification.subscriptionID ?? "N/A")")
            return
        }

        print("[iOS] Handling remote notification for record: \(recordID.recordName.prefix(8)), QueryNotificationReason: \(queryNotification.queryNotificationReason.rawValue)")
        
        Task {
            // Always reload the list of conversations as other conversations might have changed too
            // or a new one might have been created by another device.
            // However, prioritize fetching the specific conversation if it's the current one.
            if recordID.recordName == currentConversation?.id {
                print("[iOS] Notification for current conversation. Fetching it directly.")
                await fetchConversation(id: recordID.recordName)
            } else {
                 print("[iOS] Notification for a non-current conversation (\(recordID.recordName.prefix(8))). Will reload all conversations.")
                 // If not current, just loading all conversations will pick it up.
                 // We could also fetch it specifically and upsert if needed for faster update of that particular one.
            }
            // Reload all conversations to refresh the list view,
            // especially if the notification was for a record update (which our sub is for)
            await loadConversations()
        }
    }
}

// MARK: - Push delegate passthrough
extension CloudKitManager: UNUserNotificationCenterDelegate {
    // Called when app is in foreground and notification arrives
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        print("[iOS] UNUserNotificationCenter willPresent notification (app in foreground).")
        // If you used DEBUG alertBody, this allows it to show even in foreground
        // return [.banner, .sound, .badge]
        // For silent pushes, you typically don't want to present anything
        return []
    }

    // Called when user taps on a notification
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        print("[iOS] UNUserNotificationCenter didReceive response (user tapped notification).")
        let userInfo = response.notification.request.content.userInfo
        handleRemoteNotification(userInfo) // Process it the same way
    }
}

// MARK: - SwiftUI Views
struct ContentView: View {
    @EnvironmentObject private var cloud: CloudKitManager
    @State private var messageText = ""
    @State private var showList = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                if let conv = cloud.currentConversation {
                    VStack(spacing: 0) { // This VStack is our target
                        MessagesView(conv: conv, waiting: cloud.isWaitingForResponse)
                        MessageInput(text: $messageText, isFocused: _isFocused, disabled: cloud.isWaitingForResponse) {
                            send()
                        }
                    }
                    .contentShape(Rectangle()) // Keeps tap/gesture active on empty areas
                    .onTapGesture { // Existing tap-to-dismiss
                        isFocused = false
                    }
                    // <<< NEW GESTURE ADDED HERE
                    .gesture(
                        DragGesture(minimumDistance: 20, coordinateSpace: .local) // Start recognizing after 20 points of movement
                            .onEnded { value in
                                let verticalTranslation = value.translation.height
                                let horizontalTranslation = value.translation.width
                                let swipeDownwardThreshold: CGFloat = 50.0 // Minimum vertical distance for a clear downward swipe

                                // Check if it's a significant downward swipe and more vertical than horizontal
                                // 1. Vertical translation must be positive (downwards) and exceed the threshold.
                                // 2. The absolute vertical movement should be greater than absolute horizontal movement (e.g., by a factor of 1.5)
                                //    to ensure it's primarily a vertical swipe.
                                if verticalTranslation > swipeDownwardThreshold &&
                                   abs(verticalTranslation) > abs(horizontalTranslation) * 1.5 {
                                    // Uncomment for debugging if needed:
                                    // print("[Debug] Swipe down detected: v=\(verticalTranslation), h=\(horizontalTranslation). Dismissing keyboard.")
                                    isFocused = false // Dismiss the keyboard
                                }
                            }
                    )
                    // <<< END OF NEW GESTURE
                } else {
                    EmptyState { cloud.startNewConversation() }
                }
                if cloud.connectionStatus != "Connected" {
                    StatusOverlay(status: cloud.connectionStatus)
                }
            }
            .navigationTitle("Pigeon Chat")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showList.toggle() } label: { Image(systemName: "sidebar.left") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { cloud.startNewConversation() } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
        .sheet(isPresented: $showList) { ConversationList().environmentObject(cloud) }
        .alert("Error", isPresented: Binding(get: { cloud.errorMessage != nil }, set: { _ in cloud.errorMessage = nil })) {
            Button("OK", role: .cancel) { cloud.errorMessage = nil }
        } message: {
            Text(cloud.errorMessage ?? "Unknown error")
        }
    }

    private func send() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cloud.sendMessage(trimmed)
        messageText = ""
        isFocused = false // Dismiss keyboard after sending
    }
}

// MARK: Messages list
struct MessagesView: View {
    let conv: Conversation
    let waiting: Bool
    @State private var scrollViewProxy: ScrollViewProxy?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conv.messages) { msg in
                        MessageBubble(msg: msg)
                            .id(msg.id)
                    }
                    if waiting {
                        LoadingBubble()
                            .id("loading") // Ensure this ID is unique and stable
                    }
                }
                .padding() // This padding is on the LazyVStack
            }
            .onAppear {
                self.scrollViewProxy = proxy
                // Initial scroll to bottom, non-animated
                scrollToBottom(animated: false, reason: "onAppear")
            }
            // Use separate onChange modifiers for each value you want to observe
            .onChange(of: conv.messages.count) { oldCount, newCount in
                // You can use oldCount and newCount for debugging if needed
                // print("[ScrollDebug] onChange: messages.count changed from \(oldCount) to \(newCount)")
                scrollToBottom(reason: "onChange: messages.count")
            }
            .onChange(of: waiting) { oldWaiting, newWaiting in
                // You can use oldWaiting and newWaiting for debugging if needed
                // print("[ScrollDebug] onChange: waiting changed from \(oldWaiting) to \(newWaiting)")
                // This is important for scrolling to "loading" when waiting becomes true,
                // and for general state updates that might affect scroll.
                scrollToBottom(reason: "onChange: waiting")
            }
        }
    }

    // The scrollToBottom method remains the same as in the previous correct answer
    private func scrollToBottom(animated: Bool = true, reason: String) {
        guard let proxy = scrollViewProxy else {
            // print("[ScrollDebug] \(reason): Attempted to scroll but proxy is nil.")
            return
        }

        let targetID: AnyHashable?
        var animationToUse: Animation? // Use explicit Animation type or nil

        if waiting {
            targetID = "loading"
            // When "loading" appears (typically after user sends a message):
            // A very fast animation (or nil for no animation) helps avoid conflict ("fight")
            // with keyboard dismissal and text input height changes.
            animationToUse = .linear(duration: 0.05) // Very quick, almost instant
            // print("[ScrollDebug] \(reason): Target is 'loading'. Using fast animation.")
        } else if let lastMessage = conv.messages.last {
            targetID = lastMessage.id
            // When a new message arrives (and not in a loading state):
            // Use the requested animation (default is easeOut).
            animationToUse = animated ? .easeOut(duration: 0.25) : nil
            // print("[ScrollDebug] \(reason): Target is message \(lastMessage.id.uuidString.prefix(4)). Animation: \(animationToUse != nil)")
        } else {
            targetID = nil // No messages and not waiting
            // print("[ScrollDebug] \(reason): No target ID to scroll to.")
        }

        if let idToScroll = targetID {
            // Crucial: Defer to the next run loop cycle.
            // This gives SwiftUI time to process layout changes from the state update
            // before we attempt to scroll.
            DispatchQueue.main.async {
                withAnimation(animationToUse) {
                    proxy.scrollTo(idToScroll, anchor: .bottom)
                }
            }
        }
    }
}

struct MessageBubble: View {
    let msg: Message
    
    // 1. State to provide visual feedback when content is copied
    @State private var copied = false

    private var maxWidthFactor: CGFloat {
        msg.role == "assistant" ? 1.00 : 0.75
    }

    var body: some View {
        HStack {
            if msg.role == "user" { Spacer() }

            VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 5) { // Added spacing

                // ───── Message text (Unchanged) ─────
                Group {
                    if msg.role == "assistant" {
                        Markdown(msg.displayContent)
                            .markdownTheme(.basic)
                            .font(.body)
                    } else {
                        Text(msg.displayContent)
                    }
                }
                .foregroundColor(msg.role == "user" ? .white : .primary)
                .padding(12)
                .background(msg.role == "user"
                            ? Color.accentColor
                            : Color(.secondarySystemBackground))
                .cornerRadius(16)

                // 2. NEW: Meta row with timestamp and copy button
                HStack(spacing: 10) {
                    // Re-order for aesthetic reasons depending on alignment
                    if msg.role == "user" {
                        copyButton
                        timestampText
                    } else {
                        timestampText
                        copyButton
                    }
                }
                .font(.caption) // Apply font to the whole row
                .foregroundColor(.secondary) // Apply color to the whole row
            }
            .frame(maxWidth: UIScreen.main.bounds.width * maxWidthFactor,
                   alignment: msg.role == "user" ? .trailing : .leading)

            if msg.role == "assistant" { Spacer() }
        }
    }
    
    // Helper view for the timestamp to keep the body clean
    private var timestampText: some View {
        Text(msg.timestamp, style: .time)
    }

    // Helper view for the new copy button
    private var copyButton: some View {
        Button(action: copyToClipboard) {
            // Use a Label and .iconOnly to be semantic.
            // It changes icon based on the `copied` state.
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .transition(.opacity.combined(with: .scale)) // Nice animation for the change
        }
        .buttonStyle(.plain) // Use .plain to avoid the default blue tint
        .animation(.easeInOut, value: copied) // Animate the icon change
    }
    
    // 3. The function to handle the copy action and feedback
    private func copyToClipboard() {
        // Haptic feedback for a better user experience
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()

        // Copy the message's displayable content to the system clipboard
        UIPasteboard.general.string = msg.displayContent

        // Trigger the visual feedback
        copied = true

        // Reset the feedback icon after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

struct LoadingBubble: View {
    @State private var anim = false
    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 8, height: 8).scaleEffect(anim ? 1 : 0.5)
                        .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i)*0.2), value: anim)
                }
            }.padding(12).background(Color(.secondarySystemBackground)).cornerRadius(16)
            Spacer()
        }.onAppear { anim = true }
    }
}

// MARK: Input bar
struct MessageInput: View {
    @Binding var text: String
    @FocusState var isFocused: Bool
    var disabled: Bool
    var send: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            TextField("Type…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(disabled)
                .submitLabel(.send)
                .focused($isFocused)
                .onSubmit {
                    if !disabled && !text.isEmpty {
                        send()
                    }
                }
                // Prevent auto-focus when disabled (waiting for response)
                .onChange(of: disabled) { newValue in
                    if newValue {
                        isFocused = false
                    }
                }
            
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background((text.isEmpty || disabled) ? Color.gray : Color.accentColor)
                    .clipShape(Circle())
            }
            .disabled(text.isEmpty || disabled)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }
}

// MARK: Empty state
struct EmptyState: View {
    var action: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 60)).foregroundColor(.accentColor)
            Text("Start a new conversation").font(.title2).bold()
            Text("Your AI assistant is ready").foregroundColor(.secondary)
            Button(action: action) { Label("New Chat", systemImage: "plus.message") }
                .padding().frame(minWidth: 200).background(Color.accentColor).foregroundColor(.white).cornerRadius(10)
        }.padding()
    }
}

// MARK: Overlay for status
struct StatusOverlay: View { let status: String; var body: some View {
    VStack { HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange); Text(status).bold().font(.caption) }.padding(8).background(Color.orange.opacity(0.2)).cornerRadius(8).padding(); Spacer() }
}}

// MARK: List of conversations
struct ConversationList: View {
    @EnvironmentObject private var cloud: CloudKitManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            List {
                Section("Recent") {
                    ForEach(cloud.conversations) { c in
                        ConversationRow(conv: c, selected: c.id == cloud.currentConversation?.id)
                            .contentShape(Rectangle())
                            .onTapGesture { cloud.selectConversation(c); dismiss() }
                    }.onDelete { idx in idx.map { cloud.deleteConversation(cloud.conversations[$0]) } }
                }
                if let last = cloud.lastSync {
                    Section {
                        HStack { Image(systemName: "arrow.triangle.2.circlepath").foregroundColor(.green); Text("Last synced"); Spacer(); Text(last, style: .relative).foregroundColor(.secondary) }.font(.caption)
                    }
                }
            }
            .navigationTitle("Conversations")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct ConversationRow: View {
    let conv: Conversation
    let selected: Bool
    
    // Computed property to get the first user message
    var firstPrompt: String {
        conv.messages.first(where: { $0.role == "user" })?.displayContent ?? "New conversation"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(firstPrompt)
                    .lineLimit(2)
                    .font(.body)
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            HStack {
                Text("\(conv.messages.count) messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(conv.lastUpdated, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - AppDelegate & Entry Point
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = CloudKitManager.shared
        // Setup notifications once from here
        Task { await CloudKitManager.shared.setupNotifications() }
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        CloudKitManager.shared.handleRemoteNotification(userInfo)
        completionHandler(.newData)
    }
}

@main
struct Pigeon_ChatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(CloudKitManager.shared)
        }
    }
}
