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
import UIKit
import Foundation
import AVFoundation
import WhisperKit
import Network

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

enum DeviceSupport {
    static let isIPhone13OrNewer: Bool = {
        var systemInfo = utsname(); uname(&systemInfo)
        let raw = withUnsafeBytes(of: &systemInfo.machine) { ptr -> String in
            let data = Data(ptr); return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        guard raw.hasPrefix("iPhone") else { return false }
        let digits = raw.dropFirst("iPhone".count)
        guard let comma = digits.firstIndex(of: ","),
              let major = Int(digits[..<comma]) else { return false }
        return major >= 14          // iPhone14,* ⇒ iPhone 13 generation
    }()
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
    
    // MARK: - Private initialization
    private override init() {
            container  = CKContainer(identifier: Self.containerID)
            privateDB  = container.privateCloudDatabase
            super.init()

            /* -------- 1.  Immediate, synchronous cache load  -------- */
            preloadCache()                   // <= see below

            /* -------- 2.  Now start the asynchronous work   -------- */
            setupNetworkMonitoring()
            Task {
                await refreshAccountStatus()
                await ensureSubscriptionExists()
                await syncConversations()    // *network* + delta merge
            }
        }

    // MARK: Public @Published state
    @Published var currentConversation: Conversation?
    @Published var conversations: [Conversation] = []
    @Published var isWaitingForResponse = false
    @Published var errorMessage: String?
    @Published var connectionStatus: String = "Checking…"
    @Published var lastSync: Date?
    @Published var isOffline = false
    @Published var hasCachedData = false

    // MARK: Private properties
    private static let containerID = "iCloud.com.pigeonchat.pigeonchat"
    private let iOSConversationSubscriptionID = "iOSConversationNeedsResponseUpdates_v2"

    private let container: CKContainer
    let privateDB: CKDatabase
    private var pollTask: Task<Void, Never>? = nil
    private var backOff: TimeInterval = 1.0
    private var networkMonitor: NWPathMonitor?

    // MARK: - Network Monitoring
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkMonitor")
        
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self = self else { return }
                self.isOffline = path.status != .satisfied
                
                if !self.isOffline && self.conversations.isEmpty {
                    // Network restored and no data, try loading
                    await self.loadConversationsWithCache()
                }
            }
        }
        
        networkMonitor?.start(queue: queue)
    }
    
    private func preloadCache() {
            let cached = LocalCacheManager.shared.loadAllConversations()

            conversations       = cached
            currentConversation = cached.first       // optional
            hasCachedData       = !cached.isEmpty
            lastSync            = LocalCacheManager.shared.loadMetadata().lastFullSync

            print("[iOS] Pre‑loaded \(cached.count) conversations from cache")
        }

    // MARK: - Notification Setup
    func setupNotifications() async {
        UNUserNotificationCenter.current().delegate = self
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

    // MARK: - Subscription Setup
    private func ensureSubscriptionExists() async {
        // NEW: First, check the isOffline flag. If we know we're offline, don't even try.
        // This provides an immediate exit and avoids the network timeout.
        if isOffline {
            print("[iOS] Skipping subscription check: currently offline.")
            return
        }

        do {
            let existingSubscription = try await privateDB.subscription(for: iOSConversationSubscriptionID)
            print("[iOS] Subscription '\(iOSConversationSubscriptionID)' already exists.")
            return
        } catch let error as CKError where error.code == .unknownItem {
            print("[iOS] Subscription not found. Will create.")

        // --- MODIFICATION START ---
        // Specifically catch network-related errors and handle them silently.
        // CKError 3 is .networkFailure, and 4 is .networkUnavailable.
        } catch let error as CKError where error.code == .networkFailure || error.code == .networkUnavailable {
            print("[iOS] Could not check subscription due to network issue (offline). This is expected. Error: \(error.localizedDescription)")
            // IMPORTANT: We do NOT set the errorMessage here. We just log it and return.
            return
        // --- MODIFICATION END ---

        } catch {
            // This will now only catch OTHER, unexpected errors.
            print("[iOS] An unexpected error occurred while checking for subscription: \(error)")
            await MainActor.run {
                self.errorMessage = "Subscription Check Error: \(error.localizedDescription)"
            }
            return
        }

        // Create subscription (this part remains unchanged)
        print("[iOS] Creating subscription...")
        let predicate = NSPredicate(format: "needsResponse == 0")
        let subscription = CKQuerySubscription(
            recordType: "Conversation",
            predicate: predicate,
            subscriptionID: iOSConversationSubscriptionID,
            options: [.firesOnRecordUpdate]
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            let savedSubscription = try await privateDB.save(subscription)
            print("[iOS] Successfully saved subscription.")
        } catch {
            print("[iOS] Failed to save subscription: \(error)")
            await MainActor.run {
                self.errorMessage = "Subscription Error: \(error.localizedDescription)"
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
            print("[iOS] Error refreshing account status: \(error)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Conversation CRUD with Caching
    func startNewConversation() {
        let convID = UUID().uuidString
        print("[iOS] Starting new conversation with ID: \(convID.prefix(8))")
        let conv = Conversation(id: convID, messages: [], lastUpdated: .now)
        currentConversation = conv
        upsertLocally(conv)
        
        // Save to cache immediately
        try? LocalCacheManager.shared.saveConversation(conv, changeTag: nil, modificationDate: Date())
        
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
        
        // Save to cache immediately
        try? LocalCacheManager.shared.saveConversation(conv, changeTag: nil, modificationDate: Date())
        
        Task { await saveConversation(needsResponse: true) }
        startPolling()
    }

    func selectConversation(_ conv: Conversation) {
        print("[iOS] Selecting conversation \(conv.id.prefix(8))")
        currentConversation = conv
        Task { await fetchConversation(id: conv.id) }
    }

    func deleteConversation(_ conv: Conversation) {
        print("[iOS] Deleting conversation \(conv.id.prefix(8))")
        
        // Remove from cache immediately
        LocalCacheManager.shared.deleteConversation(id: conv.id)
        
        // Remove from UI
        conversations.removeAll { $0.id == conv.id }
        if currentConversation?.id == conv.id {
            currentConversation = conversations.first
        }
        
        // Remove from CloudKit
        Task {
            do {
                try await privateDB.deleteRecord(withID: CKRecord.ID(recordName: conv.id))
                print("[iOS] Deleted conversation from CloudKit")
            } catch {
                print("[iOS] Error deleting from CloudKit: \(error)")
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - CloudKit Operations with Caching
    private func loadConversationsWithCache() async {
        print("[iOS] Loading conversations with cache...")
        
        // First, load from cache for immediate UI update
        let cachedConversations = LocalCacheManager.shared.loadAllConversations()
        if !cachedConversations.isEmpty {
            conversations = cachedConversations
            hasCachedData = true
            if currentConversation == nil || !conversations.contains(where: { $0.id == currentConversation?.id }) {
                currentConversation = conversations.first
            }
            print("[iOS] Loaded \(cachedConversations.count) conversations from cache")
        }
        
        // Then sync with CloudKit if online
        if !isOffline {
            await syncConversations()
        }
    }

    @MainActor
    private func syncConversations() async {
        print("[iOS] Syncing conversations with CloudKit...")

        // Use a lightweight query to get only metadata.
        // This returns an AsyncThrowingStream which is safe to iterate over.
        let query = CKQuery(recordType: "Conversation", predicate: NSPredicate(value: true))
        let desiredKeys: [CKRecord.FieldKey]? = nil // Fetch all keys for simplicity in this corrected version.
                                                    // For extreme optimization, you could still fetch only metadata first.

        do {
            // Step 1: Fetch all records from the server using the modern, safe API.
            // This replaces the complex CKQueryOperation.
            let (matchResults, _) = try await privateDB.records(matching: query, desiredKeys: desiredKeys)
            
            var serverConversations: [String: (conversation: Conversation, record: CKRecord)] = [:]
            
            for (recordID, result) in matchResults {
                switch result {
                case .success(let record):
                    if let data = record["conversationData"] as? Data,
                       let conversation = try? JSONDecoder().decode(Conversation.self, from: data) {
                        serverConversations[recordID.recordName] = (conversation, record)
                    }
                case .failure(let error):
                    print("[iOS] Error fetching a record during sync: \(error.localizedDescription)")
                }
            }
            print("[iOS] Fetched \(serverConversations.count) full conversations from server.")

            // Step 2: Get local cache metadata.
            let localCacheMetadata = LocalCacheManager.shared.loadMetadata()
            let localIDs = Set(localCacheMetadata.conversations.keys)
            let serverIDs = Set(serverConversations.keys)

            // Step 3: Determine which records to update or add.
            var conversationsToUpdateInUI: [Conversation] = []
            for (serverID, serverData) in serverConversations {
                if let localMeta = localCacheMetadata.conversations[serverID] {
                    // Conversation exists locally. Check if server version is newer.
                    if let serverModDate = serverData.record.modificationDate, serverModDate > localMeta.lastModified {
                        print("[iOS] Updating modified conversation: \(serverID.prefix(8))")
                        try? LocalCacheManager.shared.saveConversation(
                            serverData.conversation,
                            changeTag: serverData.record.recordChangeTag,
                            modificationDate: serverData.record.modificationDate ?? Date()
                        )
                        conversationsToUpdateInUI.append(serverData.conversation)
                    }
                } else {
                    // This is a new conversation not present in the local cache.
                    print("[iOS] Adding new conversation from server: \(serverID.prefix(8))")
                    try? LocalCacheManager.shared.saveConversation(
                        serverData.conversation,
                        changeTag: serverData.record.recordChangeTag,
                        modificationDate: serverData.record.modificationDate ?? Date()
                    )
                    conversationsToUpdateInUI.append(serverData.conversation)
                }
            }

            // Step 4: Determine which local records to delete.
            let idsToDeleteLocally = localIDs.subtracting(serverIDs)
            if !idsToDeleteLocally.isEmpty {
                print("[iOS] Deleting \(idsToDeleteLocally.count) local conversations that are no longer on the server.")
                for id in idsToDeleteLocally {
                    LocalCacheManager.shared.deleteConversation(id: id)
                    conversations.removeAll { $0.id == id }
                    if currentConversation?.id == id {
                        currentConversation = nil // Will be set to the first one later
                    }
                }
            }

            // Step 5: Update the UI state.
            for conv in conversationsToUpdateInUI {
                upsertLocally(conv) // Your existing upsert function is perfect for this.
            }
            
            // If the current conversation was deleted or never set, default to the most recent one.
            if currentConversation == nil || !conversations.contains(where: { $0.id == currentConversation?.id }) {
                currentConversation = conversations.first
            }
            
            lastSync = .now
            LocalCacheManager.shared.updateLastFullSync()
            hasCachedData = !conversations.isEmpty
            print("[iOS] Sync complete. Total conversations now: \(conversations.count)")

        } catch {
            print("[iOS] Major error during sync: \(error.localizedDescription)")
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func fetchConversation(id: String) async {
        print("[iOS] Fetching conversation \(id.prefix(8))...")
        
        // Try cache first for immediate display
        if let cachedConv = LocalCacheManager.shared.loadConversation(id: id) {
            currentConversation = cachedConv
            upsertLocally(cachedConv)
            print("[iOS] Loaded conversation \(id.prefix(8)) from cache")
        }
        
        // Skip CloudKit fetch if offline
        if isOffline {
            print("[iOS] Offline - using cached version only")
            return
        }
        
        // Fetch from CloudKit to ensure we have latest
        do {
            let recordID = CKRecord.ID(recordName: id)
            let serverRecord = try await privateDB.record(for: recordID)
            
            guard let data = serverRecord["conversationData"] as? Data,
                  let fetchedConvData = try? JSONDecoder().decode(Conversation.self, from: data) else {
                print("[iOS] Failed to decode conversation from server")
                return
            }
            
            // Save to cache
            try? LocalCacheManager.shared.saveConversation(
                fetchedConvData,
                changeTag: serverRecord.recordChangeTag,
                modificationDate: serverRecord.modificationDate ?? Date()
            )
            
            // Merge with local state (same logic as before)
            var conversationToUpdate: Conversation
            var newMessagesMerged = false

            if var localCurrentConv = self.currentConversation, localCurrentConv.id == fetchedConvData.id {
                conversationToUpdate = localCurrentConv
                
                var existingMessageIDs = Set(conversationToUpdate.messages.map { $0.id })
                var messagesToAdd: [Message] = []

                for serverMessage in fetchedConvData.messages {
                    if !existingMessageIDs.contains(serverMessage.id) {
                        messagesToAdd.append(serverMessage)
                        existingMessageIDs.insert(serverMessage.id)
                        newMessagesMerged = true
                        print("[iOS] Merging new message ID: \(serverMessage.id.uuidString.prefix(8))")
                    }
                }

                if newMessagesMerged {
                    conversationToUpdate.messages.append(contentsOf: messagesToAdd)
                    conversationToUpdate.messages.sort { $0.timestamp < $1.timestamp }
                }
                conversationToUpdate.lastUpdated = fetchedConvData.lastUpdated
            } else {
                conversationToUpdate = fetchedConvData
                newMessagesMerged = true
            }
            
            // Update UI
            if newMessagesMerged || self.currentConversation?.id != conversationToUpdate.id || self.currentConversation?.lastUpdated != conversationToUpdate.lastUpdated {
                self.currentConversation = conversationToUpdate
                upsertLocally(conversationToUpdate)
            }

            // Handle waiting state
            if let lastMessage = self.currentConversation?.messages.last, self.currentConversation?.id == id {
                if lastMessage.role == "assistant" {
                    stopPolling()
                } else if lastMessage.role == "user" {
                    if !isWaitingForResponse { isWaitingForResponse = true }
                    if pollTask == nil && isWaitingForResponse { startPolling() }
                }
            } else if self.currentConversation?.id != id {
                print("[iOS] Fetched non-current conversation")
            } else {
                if isWaitingForResponse { isWaitingForResponse = false }
            }

            lastSync = .now
            
        } catch let error as CKError where error.code == .unknownItem {
            print("[iOS] Conversation \(id.prefix(8)) not found on server")
            // Remove from cache if it doesn't exist on server
            LocalCacheManager.shared.deleteConversation(id: id)
            conversations.removeAll { $0.id == id }
            if currentConversation?.id == id {
                currentConversation = conversations.first
            }
        } catch {
            print("[iOS] Error fetching conversation: \(error)")
            // Keep using cached version on error
        }
    }

    private func saveConversation(needsResponse: Bool) async {
        guard let conv = currentConversation else {
            print("[iOS] Error: saveConversation called with no currentConversation.")
            return
        }
        print("[iOS] Saving conversation \(conv.id.prefix(8)), needsResponse: \(needsResponse)")
        
        // Save to cache immediately
        try? LocalCacheManager.shared.saveConversation(
            conv,
            changeTag: nil,
            modificationDate: Date()
        )
        
        // Skip CloudKit save if offline
        if isOffline {
            print("[iOS] Offline - saved to cache only")
            return
        }
        
        do {
            let recordID = CKRecord.ID(recordName: conv.id)
            let recordToSave: CKRecord
            do {
                recordToSave = try await privateDB.record(for: recordID)
                print("[iOS] Found existing record \(conv.id.prefix(8)) to update.")
            } catch let error as CKError where error.code == .unknownItem {
                print("[iOS] Record \(conv.id.prefix(8)) not found, creating new one.")
                recordToSave = CKRecord(recordType: "Conversation", recordID: recordID)
            }

            let data = try JSONEncoder().encode(conv)
            recordToSave["conversationData"] = data as CKRecordValue
            recordToSave["lastUpdated"] = conv.lastUpdated as CKRecordValue
            recordToSave["needsResponse"] = (needsResponse ? 1 : 0) as CKRecordValue

            let savedRecord = try await privateDB.save(recordToSave)
            print("[iOS] Successfully saved to CloudKit.")
            
            // Update cache with server's change tag
            try? LocalCacheManager.shared.saveConversation(
                conv,
                changeTag: savedRecord.recordChangeTag,
                modificationDate: savedRecord.modificationDate ?? Date()
            )
            
            lastSync = .now
        } catch {
            print("[iOS] Error saving to CloudKit: \(error)")
            errorMessage = "Save Error: \(error.localizedDescription)"
        }
    }

    private func upsertLocally(_ conv: Conversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        } else {
            conversations.insert(conv, at: 0)
        }
        conversations.sort { $0.lastUpdated > $1.lastUpdated }
    }

    // MARK: - Polling
    private func startPolling() {
        guard currentConversation != nil else {
            print("[iOS] Polling not started: no current conversation.")
            return
        }
        guard isWaitingForResponse else {
            print("[iOS] Polling not started: not waiting for response.")
            stopPolling()
            return
        }

        if pollTask != nil {
            print("[iOS] Polling already active.")
            return
        }

        backOff = 1.0
        print("[iOS] Starting polling with backoff \(backOff)s.")
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isWaitingForResponse {
                if let currentConvID = self.currentConversation?.id {
                    print("[iOS] Polling... fetching \(currentConvID.prefix(8))")
                    await self.fetchConversation(id: currentConvID)
                } else {
                    print("[iOS] Polling: No current conversation ID.")
                    self.stopPolling()
                    break
                }
                
                if Task.isCancelled || !self.isWaitingForResponse { break }
                
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.backOff * 1_000_000_000))
                } catch {
                    print("[iOS] Polling sleep cancelled.")
                    break
                }
                self.backOff = min(self.backOff * 1.5, 30)
            }
            print("[iOS] Polling task ended.")
            if self.pollTask != nil {
                self.pollTask = nil
            }
        }
    }

    func stopPolling() {
        if pollTask != nil {
            print("[iOS] Stopping polling.")
            pollTask?.cancel()
            pollTask = nil
        }
        if isWaitingForResponse {
            isWaitingForResponse = false
        }
    }

    // MARK: - Remote Notifications
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        print("[iOS] Received remote notification.")
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            print("[iOS] Failed to parse CKNotification from userInfo.")
            return
        }

        guard notification.subscriptionID == iOSConversationSubscriptionID,
              let queryNotification = notification as? CKQueryNotification,
              let recordID = queryNotification.recordID else {
            print("[iOS] Notification is not for our subscription.")
            return
        }

        print("[iOS] Handling notification for record: \(recordID.recordName.prefix(8))")
        
        Task {
            if recordID.recordName == currentConversation?.id {
                print("[iOS] Notification for current conversation.")
                await fetchConversation(id: recordID.recordName)
            } else {
                print("[iOS] Notification for non-current conversation.")
            }
            await loadConversationsWithCache()
        }
    }

    // MARK: - Cache Management
    func clearLocalCache() {
        LocalCacheManager.shared.clearCache()
        conversations = []
        currentConversation = nil
        hasCachedData = false
        Task {
            await loadConversationsWithCache()
        }
    }

    func refreshConversations() async {
        await loadConversationsWithCache()
    }
}

// MARK: - Push Notification Delegate
extension CloudKitManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        print("[iOS] UNUserNotificationCenter willPresent notification")
        return []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        print("[iOS] UNUserNotificationCenter didReceive response")
        let userInfo = response.notification.request.content.userInfo
        handleRemoteNotification(userInfo)
    }
}

@MainActor
final class LocalCacheManager {
    static let shared = LocalCacheManager()
    private init() {}
    
    private let cacheDirectory: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let cacheDir = documentsPath.appendingPathComponent("ConversationCache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }()
    
    private let metadataFile: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsPath.appendingPathComponent("ConversationCache/metadata.json")
    }()
    
    // MARK: - Metadata Structures
    struct ConversationMetadata: Codable {
        let id: String
        let lastModified: Date
        let recordChangeTag: String?
    }
    
    struct CacheMetadata: Codable {
        var conversations: [String: ConversationMetadata] = [:]
        var lastFullSync: Date?
    }
    
    // MARK: - Cache Operations
    func saveConversation(_ conversation: Conversation, changeTag: String?, modificationDate: Date) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(conversation)
        
        let fileURL = cacheDirectory.appendingPathComponent("\(conversation.id).json")
        try data.write(to: fileURL)
        
        // Update metadata
        var metadata = loadMetadata()
        metadata.conversations[conversation.id] = ConversationMetadata(
            id: conversation.id,
            lastModified: modificationDate,
            recordChangeTag: changeTag
        )
        try saveMetadata(metadata)
        
        print("[Cache] Saved conversation \(conversation.id.prefix(8)) to local cache")
    }
    
    func loadConversation(id: String) -> Conversation? {
        let fileURL = cacheDirectory.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Conversation.self, from: data)
    }
    
    func loadAllConversations() -> [Conversation] {
        var conversations: [Conversation] = []
        
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            
            for file in files where file.pathExtension == "json" && file.lastPathComponent != "metadata.json" {
                if let data = try? Data(contentsOf: file),
                   let conversation = try? decoder.decode(Conversation.self, from: data) {
                    conversations.append(conversation)
                }
            }
        } catch {
            print("[Cache] Error loading conversations from cache: \(error)")
        }
        
        return conversations.sorted { $0.lastUpdated > $1.lastUpdated }
    }
    
    func deleteConversation(id: String) {
        let fileURL = cacheDirectory.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: fileURL)
        
        var metadata = loadMetadata()
        metadata.conversations.removeValue(forKey: id)
        try? saveMetadata(metadata)
        
        print("[Cache] Deleted conversation \(id.prefix(8)) from local cache")
    }
    
    func getConversationMetadata(id: String) -> ConversationMetadata? {
        let metadata = loadMetadata()
        return metadata.conversations[id]
    }
    
    // MARK: - Metadata Management
    func loadMetadata() -> CacheMetadata {
        guard let data = try? Data(contentsOf: metadataFile) else {
            return CacheMetadata()
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        guard let metadata = try? decoder.decode(CacheMetadata.self, from: data) else {
            return CacheMetadata()
        }
        
        return metadata
    }
    
    private func saveMetadata(_ metadata: CacheMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        try data.write(to: metadataFile)
    }
    
    func updateLastFullSync() {
        var metadata = loadMetadata()
        metadata.lastFullSync = Date()
        try? saveMetadata(metadata)
    }
    
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        print("[Cache] Cleared all cached conversations")
    }
    
    // MARK: - Utility Methods
    func getCacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }
        
        return totalSize
    }
    
    func getCacheSizeString() -> String {
        let size = getCacheSize()
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - FileManager Extension for Directory Size
extension FileManager {
    func allocatedSizeOfDirectory(at directoryURL: URL) throws -> UInt64 {
        let resourceKeys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        
        guard let enumerator = self.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: nil
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        
        var totalSize: UInt64 = 0
        
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: resourceKeys)
            if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                totalSize += UInt64(size)
            }
        }
        
        return totalSize
    }
}

// MARK: - SwiftUI Views
struct ContentView: View {
    @EnvironmentObject private var cloud: CloudKitManager
    @StateObject private var transcriber = WhisperTranscriber()
    @StateObject private var downloadManager = ModelDownloadManager.shared // Keep download manager
    @State private var messageText = ""
    @State private var showList = false
    @FocusState private var isFocused: Bool

    var body: some View {
        // MODIFIED: Removed the download UI check - always show main content
        NavigationView {
            ZStack {
                if let conv = cloud.currentConversation {
                    VStack(spacing: 0) {
                        MessagesView(conv: conv, waiting: cloud.isWaitingForResponse)
                        MessageInput(text: $messageText, isFocused: _isFocused, disabled: cloud.isWaitingForResponse,
                            transcriber: transcriber) {
                            send()
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isFocused = false
                    }
                    .gesture(
                        DragGesture(minimumDistance: 20, coordinateSpace: .local)
                            .onEnded { value in
                                let verticalTranslation = value.translation.height
                                let horizontalTranslation = value.translation.width
                                let swipeDownwardThreshold: CGFloat = 50.0

                                if verticalTranslation > swipeDownwardThreshold &&
                                   abs(verticalTranslation) > abs(horizontalTranslation) * 1.5 {
                                    isFocused = false
                                }
                            }
                    )
                } else {
                    EmptyState { cloud.startNewConversation() }
                }
                if cloud.connectionStatus != "Connected" || cloud.isOffline {
                    StatusOverlay(
                        status: cloud.isOffline ? "Offline Mode" : cloud.connectionStatus,
                        isOffline: cloud.isOffline
                    )
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
        .onAppear {
            // MODIFIED: Check and automatically load model if present
            Task {
                await downloadManager.checkModelStatus()
            }
            // Prevent screen from sleeping while app is active
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            // Re-enable screen sleep when leaving the app
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func send() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        cloud.sendMessage(trimmed)
        messageText = ""
        isFocused = false
    }
}

@MainActor
final class ModelDownloadManager: ObservableObject {
    static let shared = ModelDownloadManager()
    
    @Published var isDownloading = false
    @Published var isLoading = false // NEW: For loading state
    @Published var isCompiling = false // NEW: For compilation state
    @Published var downloadProgress: Float = 0.0
    @Published var statusMessage = "Checking model..."
    @Published var isModelReady = false
    @Published var showDownloadConfirmation = false // NEW: For confirmation dialog
    @Published var showCompilationAlert = false // NEW: For compilation warning
    
    private var whisperKit: WhisperKit?
    private let modelStorage = "huggingface/models/argmaxinc/whisperkit-coreml"
    private let repoName = "argmaxinc/whisperkit-coreml"
    private let targetModelName = "openai_whisper-large-v3-v20240930_turbo_632MB"
    
    private var localModelFolder: URL {
            let docs = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask).first!
            return docs
                .appendingPathComponent(modelStorage)
                .appendingPathComponent(targetModelName)
        }

        /// `true` once that folder exists on disk
        private var modelIsDownloaded: Bool {
            FileManager.default.fileExists(atPath: localModelFolder.path)
        }
    
    private init() {
        // Check if app was updated and reset compilation flag
        checkForAppUpdate()
    }
    
    private func checkForAppUpdate() {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionKey = "\(currentVersion)_\(currentBuild)"
        
        let lastVersionKey = UserDefaults.standard.string(forKey: "whisperkit_last_app_version") ?? ""
        
        if lastVersionKey != versionKey && !lastVersionKey.isEmpty {
            // App was updated, reset compilation flag
            UserDefaults.standard.removeObject(forKey: "whisperkit_model_compiled_\(targetModelName)")
            print("[ModelDownloadManager] App updated from \(lastVersionKey) to \(versionKey), reset compilation flag")
        }
        
        // Save current version
        UserDefaults.standard.set(versionKey, forKey: "whisperkit_last_app_version")
    }
    
    // NEW: Check model status and auto-load if present
    func checkModelStatus() async {
        // ❶ Fast path: nothing on disk – user must download
        guard modelIsDownloaded else {
            await MainActor.run {
                isModelReady = false
                isLoading     = false
                statusMessage = "Model not downloaded"
            }
            return
        }

        // ❷ Model folder exists – decide whether we still have to compile
        let compiledKey = "whisperkit_model_compiled_\(targetModelName)"
        let needsCompile = !UserDefaults.standard.bool(forKey: compiledKey)

        if needsCompile {
            await MainActor.run {
                showCompilationAlert = true     // ask user first
                isLoading = false
            }
        } else {
            await loadModel()                   // jump straight to loading
        }
    }
    
    // NEW: Separate method for loading/compiling model
    func loadModel() async {
        await MainActor.run {
            isLoading     = true
            isCompiling   = false
            statusMessage = "Loading model…"
        }

        let compiledKey = "whisperkit_model_compiled_\(targetModelName)"
        let firstRun    = !UserDefaults.standard.bool(forKey: compiledKey)

        do {
            var cfg = WhisperKitConfig(model: targetModelName,
                                       modelFolder: localModelFolder.path)
            cfg.download = false                // *** OFFLINE ***

            if firstRun {                       // first launch after download → compilation
                await MainActor.run {
                    isCompiling   = true
                    isLoading     = false
                    statusMessage = "Compiling Core ML model (one‑time)…"
                }
            }

            whisperKit = try await WhisperKit(cfg)
            try await whisperKit?.prewarmModels()

            if firstRun {                       // remember that compilation is done
                UserDefaults.standard.set(true, forKey: compiledKey)
            }

            await MainActor.run {
                isModelReady  = true
                isLoading     = false
                isCompiling   = false
                statusMessage = "Model ready"
            }
        } catch {
            print("[ModelDownloadManager] loadModel error:", error)
            await MainActor.run {
                isModelReady  = false
                isLoading     = false
                isCompiling   = false
                statusMessage = "Failed to load model"
            }
        }
    }
    
    // NEW: Start download after user confirmation
    func startDownload() async {
        await MainActor.run {
            isDownloading    = true
            downloadProgress = 0
            statusMessage    = "Downloading transcription model…"
        }

        do {
            // ⬇︎ 1. Download
            let folder = try await WhisperKit.download(
                variant: targetModelName,
                from:    repoName,
                progressCallback: { progress in
                    DispatchQueue.main.async {
                        self.downloadProgress = Float(progress.fractionCompleted)
                        self.statusMessage    = "Downloading… \(Int(progress.fractionCompleted*100)) %"
                    }
                })

            // ⬇︎ 2. Compile (first run only)
            await MainActor.run {
                isDownloading = false
                isCompiling   = true
                statusMessage = "Compiling model…"
            }

            var cfg = WhisperKitConfig(model: targetModelName,
                                       modelFolder: folder.path) // explicit path
            cfg.download = false                                 // stay offline

            whisperKit = try await WhisperKit(cfg)
            try await whisperKit?.prewarmModels()

            UserDefaults.standard.set(
                true,
                forKey: "whisperkit_model_compiled_\(targetModelName)")

            await MainActor.run {
                isCompiling   = false
                isModelReady  = true
                statusMessage = "Model ready"
            }

        } catch {
            print("[ModelDownloadManager] download error:", error)
            await MainActor.run {
                isDownloading = false
                isCompiling   = false
                statusMessage = "Download failed"
            }
        }
    }
    
    func getWhisperKit() -> WhisperKit? {
        return whisperKit
    }
}

@MainActor
final class WhisperTranscriber: ObservableObject {
    // MARK: Public state
    @Published var isRecording = false
    @Published var isTranscribing = false // NEW: Track transcription state
    @Published var latestTranscript: String?
    let isSupported = DeviceSupport.isIPhone13OrNewer

    // MARK: Private
    private var recorder: AVAudioRecorder?
    
    // IMPORTANT CHANGE: Get WhisperKit from the ModelDownloadManager instead of creating our own
    private var pipe: WhisperKit? {
        return ModelDownloadManager.shared.getWhisperKit()
    }

    // MARK: Recording control
    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    private func start() async {
        guard !isRecording else { return }
        
        // IMPORTANT: Check if model is ready before recording
        guard ModelDownloadManager.shared.isModelReady else {
            print("[Whisper] Model not ready yet")
            return
        }

        // Ask for microphone permission
        let granted: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
        guard granted else { return }

        // Configure the audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            print("[Whisper] AVAudioSession error:", error.localizedDescription)
            return
        }

        // Prepare AVAudioRecorder
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            recorder?.record()
            isRecording = true
        } catch {
            print("[Whisper] Failed to start recorder:", error.localizedDescription)
            recorder = nil
        }
    }

    private func stop() {
        guard let recorder else { return }
        recorder.stop()
        isRecording = false
        isTranscribing = true // NEW: Start transcribing
        Task { await transcribe(url: recorder.url) }
        self.recorder = nil
    }

    private func transcribe(url: URL) async {
        guard let pipe else {
            print("[Whisper] WhisperKit not available")
            isTranscribing = false // NEW: Reset state
            return
        }
        
        do {
            // WhisperKit returns a Transcription with .text
            if let result = try await pipe.transcribe(audioPath: url.path)?.text {
                latestTranscript = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            print("[Whisper] Transcription error:", error.localizedDescription)
        }
        
        isTranscribing = false // NEW: Transcription complete
    }
}

// MARK: Messages list
struct MessagesView: View {
    let conv: Conversation
    let waiting: Bool
    @State private var scrollViewProxy: ScrollViewProxy?
    @EnvironmentObject private var cloud: CloudKitManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Add a sync indicator at the top
                if cloud.lastSync != nil && !cloud.isOffline {
                    HStack {
                        Spacer()
                        Text("Synced")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal)
                    .padding(.top, 4)
                }
                
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conv.messages) { msg in
                        MessageBubble(msg: msg)
                            .id(msg.id)
                    }
                    if waiting {
                        LoadingBubble()
                            .id("loading")
                    }
                }
                .padding()
            }
            .onAppear {
                self.scrollViewProxy = proxy
                scrollToBottom(animated: false, reason: "onAppear")
            }
            .onChange(of: conv.messages.count) { oldCount, newCount in
                scrollToBottom(reason: "onChange: messages.count")
            }
            .onChange(of: waiting) { oldWaiting, newWaiting in
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
            // It changes icon based on the copied state.
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

// MARK: Input bar - MODIFIED
struct MessageInput: View {
    @Binding var text: String
    @FocusState var isFocused: Bool
    var disabled: Bool
    @ObservedObject var transcriber: WhisperTranscriber
    @ObservedObject private var downloadManager = ModelDownloadManager.shared // NEW: Add download manager
    @State private var showDownloadAlert = false // NEW: For alert
    var send: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            // Show compilation status if compiling
            if downloadManager.isCompiling {
                Text("Compiling transcription model for your device... This takes roughly 5 minutes and is done only once (and with each app update)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            
            HStack(spacing: 8) {

                // ——— Prompt field ———
                TextField("Type…", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .disabled(disabled)
                    .submitLabel(.send)
                    .focused($isFocused)
                    .onSubmit {
                        if !disabled && !text.isEmpty { send() }
                    }
                    .onChange(of: disabled) { if $1 { isFocused = false } }

            // ——— Mic/Download button (only supported devices) ———
            if transcriber.isSupported {
                Button {
                    if downloadManager.isModelReady {
                        // Model is ready, use as microphone
                        if !transcriber.isTranscribing { // Don't allow action during transcription
                            transcriber.toggle()
                        }
                    } else if downloadManager.isDownloading || downloadManager.isLoading || downloadManager.isCompiling {
                        // Currently downloading, loading, or compiling, do nothing
                    } else {
                        // Model not downloaded, show confirmation
                        showDownloadAlert = true
                    }
                } label: {
                    ZStack {
                        if downloadManager.isModelReady {
                            if transcriber.isTranscribing {
                                // Transcribing - show spinning circle
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                // Recording or idle
                                Image(systemName: transcriber.isRecording ? "stop.fill" : "mic.fill")
                                    .foregroundColor(.white)
                            }
                        } else if downloadManager.isDownloading {
                            // Download in progress - show progress circle
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 3)
                                .frame(width: 20, height: 20)
                            Circle()
                                .trim(from: 0, to: CGFloat(downloadManager.downloadProgress))
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 20, height: 20)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear, value: downloadManager.downloadProgress)
                        } else if downloadManager.isLoading || downloadManager.isCompiling {
                            // Loading or compiling model - show spinning circle
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            // Download icon
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .background(
                        downloadManager.isModelReady ?
                            (transcriber.isRecording ? Color.red :
                             (transcriber.isTranscribing ? Color.orange : Color.accentColor)) :
                            ((downloadManager.isDownloading || downloadManager.isLoading || downloadManager.isCompiling) ? Color.gray : Color.accentColor)
                    )
                    .clipShape(Circle())
                }
                .disabled(downloadManager.isDownloading || downloadManager.isLoading || downloadManager.isCompiling || transcriber.isTranscribing)
                .accessibilityLabel(
                    downloadManager.isModelReady ?
                        (transcriber.isRecording ? "Stop recording" :
                         (transcriber.isTranscribing ? "Processing speech" : "Start recording")) :
                        (downloadManager.isDownloading ? "Downloading model" :
                         (downloadManager.isLoading ? "Loading model" :
                          (downloadManager.isCompiling ? "Compiling model" : "Download voice model")))
                )
                .alert("Download Voice Transcription Model", isPresented: $showDownloadAlert) {
                    Button("Cancel", role: .cancel) { }
                    Button("Continue") {
                        Task {
                            await downloadManager.startDownload()
                        }
                    }
                } message: {
                    Text("Do you want to download a local transcription model? It will allow you to prompt with your voice. The model weighs roughly 600 MB. After the download is complete, there will be a one time compilation process that can take up to 5 minutes.")
                }
                .alert("Model Compilation Required",
                       isPresented: $downloadManager.showCompilationAlert) {
                    // ① Optional cancel / dismiss
                    Button("Not now", role: .cancel) {
                        // You can update the status if you wish
                        downloadManager.statusMessage = "Model not compiled"
                    }

                    // ② Proceed with compilation
                    Button("Continue") {
                        Task { await downloadManager.loadModel() }
                    }
                } message: {
                    Text("The voice model needs to be compiled for your device. This is an intensive process that only happens once (and after app updates) and takes roughly 5 minutes. Please keep the app open during this process.")
                }
            }

                // ——— Send button ———
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
        }
        .background(Color(.systemBackground))
        // When a new transcript arrives, stuff it into the field
        .onReceive(transcriber.$latestTranscript.compactMap { $0 }) { transcript in
            text = transcript
            isFocused = true
        }
        // Reset transcript when starting new recording
        .onChange(of: transcriber.isRecording) { oldValue, newValue in
            if newValue {
                // Clear previous transcript when starting new recording
                transcriber.latestTranscript = nil
            }
        }
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
struct StatusOverlay: View {
    let status: String
    var isOffline: Bool = false
    
    var body: some View {
        VStack {
            HStack {
                Image(systemName: isOffline ? "wifi.slash" : "exclamationmark.triangle.fill")
                    .foregroundColor(isOffline ? .blue : .orange)
                Text(status)
                    .bold()
                    .font(.caption)
                if isOffline {
                    Text("(Using cached data)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
            .background((isOffline ? Color.blue : Color.orange).opacity(0.2))
            .cornerRadius(8)
            .padding()
            Spacer()
        }
    }
}

// MARK: List of conversations
struct ConversationList: View {
    @EnvironmentObject private var cloud: CloudKitManager
    @Environment(\.dismiss) private var dismiss
    @State private var showCacheSettings = false
    
    var body: some View {
        NavigationView {
            List {
                Section("Recent") {
                    ForEach(cloud.conversations) { c in
                        ConversationRow(conv: c, selected: c.id == cloud.currentConversation?.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                cloud.selectConversation(c)
                                dismiss()
                            }
                    }
                    .onDelete { idx in
                        idx.map { cloud.deleteConversation(cloud.conversations[$0]) }
                    }
                }
                
                // Sync Status Section
                Section {
                    if let last = cloud.lastSync {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.green)
                            Text("Last synced")
                            Spacer()
                            Text(last, style: .relative)
                                .foregroundColor(.secondary)
                        }
                        .font(.caption)
                    }
                    
                    if cloud.isOffline {
                        HStack {
                            Image(systemName: "wifi.slash")
                                .foregroundColor(.blue)
                            Text("Offline - Using cached data")
                                .font(.caption)
                        }
                    }
                    
                    Button {
                        showCacheSettings = true
                    } label: {
                        HStack {
                            Image(systemName: "internaldrive")
                            Text("Cache: \(LocalCacheManager.shared.getCacheSizeString())")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable {
                await cloud.refreshConversations()
            }
            .sheet(isPresented: $showCacheSettings) {
                CacheSettingsView()
                    .environmentObject(cloud)
            }
        }
    }
}

struct CacheSettingsView: View {
    @EnvironmentObject private var cloud: CloudKitManager
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirmation = false
    
    var body: some View {
        NavigationView {
            List {
                Section("Cache Information") {
                    HStack {
                        Text("Cache Size")
                        Spacer()
                        Text(LocalCacheManager.shared.getCacheSizeString())
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Cached Conversations")
                        Spacer()
                        Text("\(cloud.conversations.count)")
                            .foregroundColor(.secondary)
                    }
                    
                    if let lastSync = LocalCacheManager.shared.loadMetadata().lastFullSync {
                        HStack {
                            Text("Last Full Sync")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section {
                    Button {
                        showClearConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                            Text("Clear Local Cache")
                                .foregroundColor(.red)
                        }
                    }
                } footer: {
                    Text("Clearing the cache will remove all locally stored conversations. They will be re-downloaded from iCloud when needed.")
                        .font(.caption)
                }
                
                Section("About Caching") {
                    Text("Conversations are cached locally for offline access and faster loading. Only modified conversations are synced with iCloud to save bandwidth.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Cache Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Clear Cache?", isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    cloud.clearLocalCache()
                    dismiss()
                }
            } message: {
                Text("This will remove all cached conversations. They will be re-downloaded when you open them.")
            }
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
        // Prevent screen dimming while app is active
        UIApplication.shared.isIdleTimerDisabled = true
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        CloudKitManager.shared.handleRemoteNotification(userInfo)
        completionHandler(.newData)
    }
    
    func applicationWillResignActive(_ application: UIApplication) {
        // Re-enable idle timer when app goes to background
        UIApplication.shared.isIdleTimerDisabled = false
    }
    
    func applicationDidBecomeActive(_ application: UIApplication) {
        // Disable idle timer when app becomes active
        UIApplication.shared.isIdleTimerDisabled = true
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
