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
import Vision
import VisionKit
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Shared Models (Ensure these are identical to macOS app's models)
struct Message: Identifiable, Codable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date
    let attachmentText: String? // NEW: Add this property

    // Update the initializer
    init(id: UUID = UUID(), role: String, content: String, timestamp: Date, attachmentText: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.attachmentText = attachmentText
    }

    // Update CodingKeys
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, attachmentText
    }

    // Update decoder
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(String.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.attachmentText = try container.decodeIfPresent(String.self, forKey: .attachmentText)
    }

    // Update encoder
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.content, forKey: .content)
        try container.encode(self.timestamp, forKey: .timestamp)
        try container.encodeIfPresent(self.attachmentText, forKey: .attachmentText)
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

enum ModelProvider: String, CaseIterable {
    case builtIn = "Built-in"
    case lmstudio = "LM Studio"
    case ollama = "Ollama"
    
    var displayName: String { rawValue }
}

struct ModelOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let provider: ModelProvider
    let requiresRAM: String? // For built-in models
    
    static let allOptions: [ModelOption] = [
        // Built-in models
        ModelOption(id: "qwen3-0.6b", displayName: "Qwen3 0.6B", provider: .builtIn, requiresRAM: "0.5 GB"),
        ModelOption(id: "qwen3-4b", displayName: "Qwen3 4B", provider: .builtIn, requiresRAM: "2.5 GB"),
        ModelOption(id: "qwen3-8b", displayName: "Qwen3 8B", provider: .builtIn, requiresRAM: "5 GB"),
        ModelOption(id: "qwen3-14b", displayName: "Qwen3 14B", provider: .builtIn, requiresRAM: "9 GB"),
        ModelOption(id: "qwen3-30b-a3b", displayName: "Qwen3 30B", provider: .builtIn, requiresRAM: "18 GB"),
        ModelOption(id: "qwen3-32b", displayName: "Qwen3 32B", provider: .builtIn, requiresRAM: "20 GB"),
        
        // External providers
        ModelOption(id: "lmstudio", displayName: "LM Studio", provider: .lmstudio, requiresRAM: nil),
        ModelOption(id: "ollama", displayName: "Ollama", provider: .ollama, requiresRAM: nil)
    ]
    
    var fullDisplayName: String {
        if let ram = requiresRAM {
            return "\(displayName) (\(ram))"
        }
        return displayName
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
        preloadCache()

        /* ---- NEW: create a fresh, empty conversation right away ---- */
        startNewConversation()          // ← this is the one-liner you add

        /* -------- 2.  Now start the asynchronous work   -------- */
        setupNetworkMonitoring()
        Task {
            await refreshAccountStatus()
            await ensureSubscriptionExists()
            await syncConversations()

            // --- Create the blank conversation *after* CloudKit has synced ---
            //await MainActor.run { self.startNewConversation() }
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
    @Published var isServerGenerating = false
    @Published var serverGeneratingConversationId: String?
    @Published var isStopRequestInProgress = false
    
    @AppStorage("enableWebSearch") var enableWebSearch: Bool = false
    @AppStorage("selectedModelId") var selectedModelId: String = "qwen3-4b"
    @AppStorage("builtInSystemPrompt") var builtInSystemPrompt: String = "/no_think"
    @AppStorage("builtInContextValue") var builtInContextValue: Int = 16000
    @AppStorage("builtInTemperatureValue") var builtInTemperatureValue: Double = 0.7
    @AppStorage("builtInTopKValue") var builtInTopKValue: Int = 20
    @AppStorage("builtInTopPValue") var builtInTopPValue: Double = 0.8
    
    // LMStudio parameters
    @AppStorage("lmstudioSystemPrompt") var lmstudioSystemPrompt: String = ""
    @AppStorage("lmstudioMaxTokensEnabled") var lmstudioMaxTokensEnabled: Bool = false
    @AppStorage("lmstudioMaxTokensValue") var lmstudioMaxTokensValue: Int = 4096
    @AppStorage("lmstudioTemperatureEnabled") var lmstudioTemperatureEnabled: Bool = false
    @AppStorage("lmstudioTemperatureValue") var lmstudioTemperatureValue: Double = 0.7
    @AppStorage("lmstudioTopPEnabled") var lmstudioTopPEnabled: Bool = false
    @AppStorage("lmstudioTopPValue") var lmstudioTopPValue: Double = 0.9

    // Ollama parameters
    @AppStorage("ollamaSystemPrompt") var ollamaSystemPrompt: String = ""
    @AppStorage("ollamaMaxTokensEnabled") var ollamaMaxTokensEnabled: Bool = false
    @AppStorage("ollamaMaxTokensValue") var ollamaMaxTokensValue: Int = 4096
    @AppStorage("ollamaTemperatureEnabled") var ollamaTemperatureEnabled: Bool = false
    @AppStorage("ollamaTemperatureValue") var ollamaTemperatureValue: Double = 0.7
    @AppStorage("ollamaTopPEnabled") var ollamaTopPEnabled: Bool = false
    @AppStorage("ollamaTopPValue") var ollamaTopPValue: Double = 0.9
    
    // Add these after existing @AppStorage properties
    @AppStorage("enableThinking") var enableThinking: Bool = false

    // Thinking mode parameters (local storage only)
    @AppStorage("thinkingSystemPrompt") var thinkingSystemPrompt: String = ""
    @AppStorage("thinkingContextValue") var thinkingContextValue: Int = 16000
    @AppStorage("thinkingTemperatureValue") var thinkingTemperatureValue: Double = 0.6
    @AppStorage("thinkingTopKValue") var thinkingTopKValue: Int = 20
    @AppStorage("thinkingTopPValue") var thinkingTopPValue: Double = 0.95
    
    // LMStudio thinking parameters
    @AppStorage("lmstudioThinkingSystemPrompt") var lmstudioThinkingSystemPrompt: String = ""
    @AppStorage("lmstudioThinkingMaxTokensEnabled") var lmstudioThinkingMaxTokensEnabled: Bool = false
    @AppStorage("lmstudioThinkingMaxTokensValue") var lmstudioThinkingMaxTokensValue: Int = 4096
    @AppStorage("lmstudioThinkingTemperatureEnabled") var lmstudioThinkingTemperatureEnabled: Bool = false
    @AppStorage("lmstudioThinkingTemperatureValue") var lmstudioThinkingTemperatureValue: Double = 0.6
    @AppStorage("lmstudioThinkingTopPEnabled") var lmstudioThinkingTopPEnabled: Bool = false
    @AppStorage("lmstudioThinkingTopPValue") var lmstudioThinkingTopPValue: Double = 0.95
    @AppStorage("lmstudioModelName") var lmstudioModelName: String = "add model in settings"
    
    // Ollama thinking parameters
    @AppStorage("ollamaThinkingSystemPrompt") var ollamaThinkingSystemPrompt: String = ""
    @AppStorage("ollamaThinkingMaxTokensEnabled") var ollamaThinkingMaxTokensEnabled: Bool = false
    @AppStorage("ollamaThinkingMaxTokensValue") var ollamaThinkingMaxTokensValue: Int = 4096
    @AppStorage("ollamaThinkingTemperatureEnabled") var ollamaThinkingTemperatureEnabled: Bool = false
    @AppStorage("ollamaThinkingTemperatureValue") var ollamaThinkingTemperatureValue: Double = 0.6
    @AppStorage("ollamaThinkingTopPEnabled") var ollamaThinkingTopPEnabled: Bool = false
    @AppStorage("ollamaThinkingTopPValue") var ollamaThinkingTopPValue: Double = 0.95
    @AppStorage("ollamaModelName") var ollamaModelName: String = "add model in settings"
    
    @AppStorage("transcriptionEnabled") var transcriptionEnabled: Bool = true

    // MARK: Private properties
    private static let containerID = "iCloud.com.pigeonchat.pigeonchat"
    private let iOSConversationSubscriptionID = "iOSConversationNeedsResponseUpdates_v2"

    private let container: CKContainer
    let privateDB: CKDatabase
    private var pollTask: Task<Void, Never>? = nil
    private var backOff: TimeInterval = 1.0
    private var networkMonitor: NWPathMonitor?
    var selectedModel: ModelOption {
            ModelOption.allOptions.first { $0.id == selectedModelId } ?? ModelOption.allOptions[1]
        }
    
    var isThinkingAvailable: Bool {
        switch selectedModel.provider {
        case .builtIn:
            return true // Always available for built-in
        case .lmstudio:
            // Check if any thinking parameter is configured
            return !lmstudioThinkingSystemPrompt.isEmpty ||
                   lmstudioThinkingMaxTokensEnabled ||
                   lmstudioThinkingTemperatureEnabled ||
                   lmstudioThinkingTopPEnabled
        case .ollama:
            // Check if any thinking parameter is configured
            return !ollamaThinkingSystemPrompt.isEmpty ||
                   ollamaThinkingMaxTokensEnabled ||
                   ollamaThinkingTemperatureEnabled ||
                   ollamaThinkingTopPEnabled
        }
    }
    
    var currentDisplayName: String {
            displayName(for: selectedModel)
        }
    
    var conversationSizePercentage: Double {
        guard let conv = currentConversation else { return 0 }
        let currentSize = calculateConversationSize(conv)
        return Double(currentSize) / 800_000.0
    }

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
    
    @MainActor
    private func ensureConversationExists() {
        if currentConversation == nil && conversations.isEmpty {
            print("[iOS] No conversations exist, creating new one automatically")
            startNewConversation()
        }
    }
    
    private func preloadCache() {
        let cached = LocalCacheManager.shared.loadAllConversations()

        conversations       = cached
        //currentConversation = cached.first
        hasCachedData       = !cached.isEmpty
        lastSync            = LocalCacheManager.shared.loadMetadata().lastFullSync

        print("[iOS] Pre‑loaded \(cached.count) conversations from cache")
        
        // Add this line to ensure we have a conversation
        //ensureConversationExists()
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
    
    private func pruneEmptyConversations() {
        let doomed = conversations.filter {
            $0.messages.isEmpty && $0.id != currentConversation?.id
        }
        guard !doomed.isEmpty else { return }

        print("[iOS] Pruning \(doomed.count) empty conversations")

        for conv in doomed {
            // ① remove from local cache + in-memory list
            LocalCacheManager.shared.deleteConversation(id: conv.id)
            conversations.removeAll { $0.id == conv.id }

            // ② remove from CloudKit (best-effort)
            Task {
                do { try await privateDB.deleteRecord(withID: CKRecord.ID(recordName: conv.id)) }
                catch { print("[iOS] Cloud delete failed for \(conv.id.prefix(8)): \(error)") }
            }
        }
    }

    // MARK: - Conversation CRUD with Caching
    func startNewConversation() {
        pruneEmptyConversations()
        let convID = UUID().uuidString
        print("[iOS] Starting new conversation with ID: \(convID.prefix(8))")
        let conv = Conversation(id: convID, messages: [], lastUpdated: .now)
        currentConversation = conv
        upsertLocally(conv)
        
        // Save to cache immediately
        try? LocalCacheManager.shared.saveConversation(conv, changeTag: nil, modificationDate: Date())
        
        Task { await saveConversation(needsResponse: false) }
    }

    func sendMessage(_ text: String, attachmentText: String? = nil) {
        guard var conv = currentConversation else {
            print("[iOS] Error: sendMessage called with no currentConversation.")
            return
        }
        print("[iOS] Sending message in conversation \(conv.id.prefix(8))")
        
        // Combine user text with attachment context if present
        let fullContent: String
        if let attachmentText = attachmentText {
            fullContent = "\(text)\n\n[Attached content]:\n\(attachmentText)"
        } else {
            fullContent = text
        }
        
        // Create the message to check size
        let userMsg = Message(role: "user", content: fullContent, timestamp: .now, attachmentText: attachmentText)
        
        // Check if adding this message would exceed the size limit
        let projectedSize = calculateConversationSize(conv, additionalMessage: userMsg)
        let characterLimit = 800_000 // 800k characters as requested
        
        // Rough estimate: 1 character ≈ 1 byte for ASCII, up to 4 bytes for Unicode
        // To be safe, we'll check both character count and actual byte size
        let totalCharacters = conv.messages.reduce(0) { $0 + $1.content.count } + fullContent.count
        
        if projectedSize > characterLimit || totalCharacters > characterLimit {
            // Show error and don't send
            Task { @MainActor in
                self.errorMessage = "Message too large. This conversation is approaching the size limit. Please start a new conversation."
            }
            return
        }
        
        // If size check passes, proceed with sending
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
        
        // Clear any stuck generating state when switching conversations
        if serverGeneratingConversationId != nil && serverGeneratingConversationId != conv.id {
            clearGeneratingState()
        }
        
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
            if conversations.isEmpty {
                // If this was the last conversation, create a new one
                startNewConversation()
            } else {
                currentConversation = conversations.first
            }
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
            let idsToDeleteLocally = localIDs
                .subtracting(serverIDs)
                .filter { id in
                    guard let meta = localCacheMetadata.conversations[id] else { return false }
                    return meta.recordChangeTag != nil          // keep never-synced locals
                }
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
            if currentConversation == nil,
               let first = conversations.first {
                currentConversation = first
            }
                
                lastSync = .now
                LocalCacheManager.shared.updateLastFullSync()
                pruneEmptyConversations()
                hasCachedData = !conversations.isEmpty
                print("[iOS] Sync complete. Total conversations now: \(conversations.count)")
            } catch {
            print("[iOS] Major error during sync: \(error.localizedDescription)")
            errorMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    func requestStopGeneration() {
        guard let convId = serverGeneratingConversationId else { return }
        guard !isStopRequestInProgress else {
            print("[iOS] Stop request already in progress, ignoring additional press")
            return
        }
        
        print("[iOS] Requesting server to stop generation for \(convId.prefix(8))")
        isStopRequestInProgress = true
        
        Task {
            do {
                let recordID = CKRecord.ID(recordName: convId)
                let record = try await privateDB.record(for: recordID)
                
                // Check if stop was already requested
                if let stopRequested = record["stopRequested"] as? NSNumber, stopRequested.boolValue == true {
                    print("[iOS] Stop already requested, skipping duplicate")
                    await MainActor.run {
                        self.isStopRequestInProgress = false
                    }
                    return
                }
                
                record["stopRequested"] = 1 as CKRecordValue
                _ = try await privateDB.save(record)
                print("[iOS] Stop request sent to server for \(convId.prefix(8))")
                
                // Keep the flag set until we see the server has stopped
                // It will be cleared when fetchConversation sees isGenerating = false
                
                // Start polling more aggressively to catch the state change
                if pollTask == nil {
                    startPolling()
                }
            } catch {
                print("[iOS] Error sending stop request: \(error)")
                await MainActor.run {
                    self.errorMessage = "Failed to send stop request. Please try again."
                    self.isStopRequestInProgress = false
                }
            }
        }
    }

    // Update the clearGeneratingState method to also clear the stop request flag:
    func clearGeneratingState() {
        isServerGenerating = false
        serverGeneratingConversationId = nil
        isStopRequestInProgress = false
        print("[iOS] Manually cleared generating state")
    }

    // Update fetchConversation to clear the stop request flag when generation stops:
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
            
            // Check if server is generating - ALWAYS update the state based on server
            let isGenerating = (serverRecord["isGenerating"] as? NSNumber)?.boolValue ?? false
            
            await MainActor.run {
                if isGenerating && currentConversation?.id == id {
                    self.isServerGenerating = true
                    self.serverGeneratingConversationId = id
                    print("[iOS] Server is generating response for \(id.prefix(8))")
                } else {
                    // Always clear if not generating or different conversation
                    if self.serverGeneratingConversationId == id || self.currentConversation?.id == id {
                        self.isServerGenerating = false
                        self.serverGeneratingConversationId = nil
                        self.isStopRequestInProgress = false // Clear this too
                        print("[iOS] Server not generating for \(id.prefix(8)) - clearing state")
                    }
                }
            }
            
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

            // Handle waiting state - check for "Response interrupted" message
            if let lastMessage = self.currentConversation?.messages.last, self.currentConversation?.id == id {
                if lastMessage.role == "assistant" {
                    stopPolling()
                    // Clear server generating state if we see an assistant message
                    if lastMessage.content == "Response interrupted" && (isServerGenerating || isStopRequestInProgress) {
                        await MainActor.run {
                            self.isServerGenerating = false
                            self.serverGeneratingConversationId = nil
                            self.isStopRequestInProgress = false
                            print("[iOS] Detected interrupted response - clearing all states")
                        }
                    }
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
    
    
    private func calculateConversationSize(_ conversation: Conversation, additionalMessage: Message? = nil) -> Int {
        var tempConversation = conversation
        if let additionalMessage = additionalMessage {
            tempConversation.messages.append(additionalMessage)
        }
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(tempConversation)
            return data.count
        } catch {
            // If encoding fails, return a large number to prevent sending
            return Int.max
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
            
            // Save web search preference
            recordToSave["enableWebSearch"] = (enableWebSearch ? 1 : 0) as CKRecordValue
            
            // Save model selection
            recordToSave["selectedModelId"] = selectedModelId as CKRecordValue
            recordToSave["selectedProvider"] = selectedModel.provider.rawValue as CKRecordValue
            
            recordToSave["lmstudioModelName"] = lmstudioModelName as CKRecordValue
            recordToSave["ollamaModelName"] = ollamaModelName as CKRecordValue
            
            // Save built-in model settings - USE THINKING PARAMETERS IF THINKING IS ENABLED
            if selectedModel.provider == .builtIn && enableThinking {
                // When thinking is enabled, save thinking parameters to the standard fields
                recordToSave["builtInSystemPrompt"] = thinkingSystemPrompt as CKRecordValue
                recordToSave["builtInContextValue"] = thinkingContextValue as CKRecordValue
                recordToSave["builtInTemperatureValue"] = thinkingTemperatureValue as CKRecordValue
                recordToSave["builtInTopKValue"] = thinkingTopKValue as CKRecordValue
                recordToSave["builtInTopPValue"] = thinkingTopPValue as CKRecordValue
            } else {
                // Otherwise save regular parameters
                recordToSave["builtInSystemPrompt"] = builtInSystemPrompt as CKRecordValue
                recordToSave["builtInContextValue"] = builtInContextValue as CKRecordValue
                recordToSave["builtInTemperatureValue"] = builtInTemperatureValue as CKRecordValue
                recordToSave["builtInTopKValue"] = builtInTopKValue as CKRecordValue
                recordToSave["builtInTopPValue"] = builtInTopPValue as CKRecordValue
            }
            
            // Save LMStudio settings - USE THINKING PARAMETERS IF THINKING IS ENABLED
            if selectedModel.provider == .lmstudio && enableThinking {
                // When thinking is enabled for LMStudio, save thinking parameters
                recordToSave["lmstudioSystemPrompt"] = lmstudioThinkingSystemPrompt as CKRecordValue
                recordToSave["lmstudioMaxTokensEnabled"] = (lmstudioThinkingMaxTokensEnabled ? 1 : 0) as CKRecordValue
                recordToSave["lmstudioMaxTokensValue"] = lmstudioThinkingMaxTokensValue as CKRecordValue
                recordToSave["lmstudioTemperatureEnabled"] = (lmstudioThinkingTemperatureEnabled ? 1 : 0) as CKRecordValue
                recordToSave["lmstudioTemperatureValue"] = lmstudioThinkingTemperatureValue as CKRecordValue
                recordToSave["lmstudioTopPEnabled"] = (lmstudioThinkingTopPEnabled ? 1 : 0) as CKRecordValue
                recordToSave["lmstudioTopPValue"] = lmstudioThinkingTopPValue as CKRecordValue
            } else {
                // Otherwise save regular LMStudio parameters
                recordToSave["lmstudioSystemPrompt"] = lmstudioSystemPrompt as CKRecordValue
                recordToSave["lmstudioMaxTokensEnabled"] = (lmstudioMaxTokensEnabled ? 1 : 0) as CKRecordValue
                recordToSave["lmstudioMaxTokensValue"] = lmstudioMaxTokensValue as CKRecordValue
                recordToSave["lmstudioTemperatureEnabled"] = (lmstudioTemperatureEnabled ? 1 : 0) as CKRecordValue
                recordToSave["lmstudioTemperatureValue"] = lmstudioTemperatureValue as CKRecordValue
                recordToSave["lmstudioTopPEnabled"] = (lmstudioTopPEnabled ? 1 : 0) as CKRecordValue
                recordToSave["lmstudioTopPValue"] = lmstudioTopPValue as CKRecordValue
            }

            // Save Ollama settings - USE THINKING PARAMETERS IF THINKING IS ENABLED
            if selectedModel.provider == .ollama && enableThinking {
                // When thinking is enabled for Ollama, save thinking parameters
                recordToSave["ollamaSystemPrompt"] = ollamaThinkingSystemPrompt as CKRecordValue
                recordToSave["ollamaMaxTokensEnabled"] = (ollamaThinkingMaxTokensEnabled ? 1 : 0) as CKRecordValue
                recordToSave["ollamaMaxTokensValue"] = ollamaThinkingMaxTokensValue as CKRecordValue
                recordToSave["ollamaTemperatureEnabled"] = (ollamaThinkingTemperatureEnabled ? 1 : 0) as CKRecordValue
                recordToSave["ollamaTemperatureValue"] = ollamaThinkingTemperatureValue as CKRecordValue
                recordToSave["ollamaTopPEnabled"] = (ollamaThinkingTopPEnabled ? 1 : 0) as CKRecordValue
                recordToSave["ollamaTopPValue"] = ollamaThinkingTopPValue as CKRecordValue
            } else {
                // Otherwise save regular Ollama parameters
                recordToSave["ollamaSystemPrompt"] = ollamaSystemPrompt as CKRecordValue
                recordToSave["ollamaMaxTokensEnabled"] = (ollamaMaxTokensEnabled ? 1 : 0) as CKRecordValue
                recordToSave["ollamaMaxTokensValue"] = ollamaMaxTokensValue as CKRecordValue
                recordToSave["ollamaTemperatureEnabled"] = (ollamaTemperatureEnabled ? 1 : 0) as CKRecordValue
                recordToSave["ollamaTemperatureValue"] = ollamaTemperatureValue as CKRecordValue
                recordToSave["ollamaTopPEnabled"] = (ollamaTopPEnabled ? 1 : 0) as CKRecordValue
                recordToSave["ollamaTopPValue"] = ollamaTopPValue as CKRecordValue
            }

            let savedRecord = try await privateDB.save(recordToSave)
                    print("[iOS] Successfully saved to CloudKit with model: \(selectedModel.displayName), thinking: \(enableThinking)")
                    
                    // Update cache with server's change tag
                    try? LocalCacheManager.shared.saveConversation(
                        conv,
                        changeTag: savedRecord.recordChangeTag,
                        modificationDate: savedRecord.modificationDate ?? Date()
                    )
                    
                    lastSync = .now
                } catch let error as CKError where error.code == .serverRecordChanged {
                    // Handle the case where record was modified between fetch and save
                    print("[iOS] Record was modified on server, retrying...")
                    await saveConversation(needsResponse: needsResponse)
                } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                    // Handle zone issues
                    print("[iOS] Zone issue: \(error). Will retry on next sync.")
                } catch {
                    print("[iOS] Error saving to CloudKit: \(error)")
                    // Only show user-facing errors for non-recoverable issues
                    if !isHandleableError(error) {
                        errorMessage = "Save Error: \(error.localizedDescription)"
                    }
                }
            }

            private func isHandleableError(_ error: Error) -> Bool {
                guard let ckError = error as? CKError else { return false }
                
                switch ckError.code {
                case .serverRecordChanged, .zoneNotFound, .userDeletedZone, .changeTokenExpired:
                    return true
                default:
                    return false
                }
            }
    
    func displayName(for option: ModelOption) -> String {
            switch option.provider {
            case .lmstudio:
                return lmstudioModelName.isEmpty ? option.displayName : lmstudioModelName
            case .ollama:
                return ollamaModelName.isEmpty ? option.displayName : ollamaModelName
            case .builtIn:
                return option.displayName
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
final class AttachmentManager: ObservableObject {
    @Published var attachments: [Attachment] = []
    @Published var isProcessing = false
    @Published var errorMessage: String?
    
    struct Attachment: Identifiable {
        let id = UUID()
        let fileName: String
        let extractedText: String
        let type: AttachmentType
        
        enum AttachmentType {
            case image, pdf
        }
    }
    
    var hasAttachments: Bool {
        !attachments.isEmpty
    }
    
    var combinedAttachmentText: String? {
        guard !attachments.isEmpty else { return nil }
        
        return attachments.enumerated().map { index, attachment in
            "[Attachment \(index + 1): \(attachment.fileName)]\n\(attachment.extractedText)"
        }.joined(separator: "\n\n")
    }
    
    func clearAllAttachments() {
        attachments.removeAll()
        errorMessage = nil
    }
    
    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }
    
    func processImage(_ image: UIImage, fileName: String = "Image") async {
        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }
        
        guard let cgImage = image.cgImage else {
            await MainActor.run {
                errorMessage = "Failed to process image"
                isProcessing = false
            }
            return
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation],
                  error == nil else {
                Task { @MainActor in
                    self?.errorMessage = "Failed to extract text from image"
                    self?.isProcessing = false
                }
                return
            }
            
            let extractedText = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            
            Task { @MainActor in
                if !extractedText.isEmpty {
                    self?.attachments.append(Attachment(
                        fileName: fileName,
                        extractedText: extractedText,
                        type: .image
                    ))
                }
                self?.isProcessing = false
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        do {
            try requestHandler.perform([request])
        } catch {
            await MainActor.run {
                errorMessage = "OCR failed: \(error.localizedDescription)"
                isProcessing = false
            }
        }
    }
    
    func processPDF(at url: URL, fileName: String) async {
        await MainActor.run {
            isProcessing = true
            errorMessage = nil
        }
        
        // Clean up temporary file when done
        defer {
            if url.path.contains(NSTemporaryDirectory()) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        guard let document = PDFDocument(url: url) else {
            await MainActor.run {
                errorMessage = "Failed to load PDF"
                isProcessing = false
            }
            return
        }
        
        var fullText = ""
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            if let pageText = page.string {
                fullText += pageText + "\n\n"
            }
        }
        
        await MainActor.run {
            if !fullText.isEmpty {
                attachments.append(Attachment(
                    fileName: fileName,
                    extractedText: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                    type: .pdf
                ))
            }
            isProcessing = false
        }
    }
}


struct ModelSelectorView: View {
    @EnvironmentObject private var cloud: CloudKitManager

    /// (Optional) keep provider grouping for a tidy menu
    private var grouped: [(provider: ModelProvider, models: [ModelOption])] {
        Dictionary(grouping: ModelOption.allOptions, by: \.provider)
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { ($0.key, $0.value) }
    }

    var body: some View {
            Menu {
                ForEach(grouped, id: \.provider) { group in
                    Text(group.provider.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .disabled(true)

                    ForEach(group.models) { option in
                        Button {
                            cloud.selectedModelId = option.id
                        } label: {
                            Label(
                                cloud.displayName(for: option),   // ← uses helper
                                systemImage: cloud.selectedModelId == option.id ? "checkmark" : ""
                            )
                        }
                    }

                    if group.provider != grouped.last?.provider { Divider() }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(cloud.currentDisplayName)              // ← uses helper
                        .font(.system(size: 16, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                }
                .foregroundColor(.primary)
            }
            .menuStyle(.automatic)
        }
    }


struct SettingsView: View {
    @EnvironmentObject private var cloud: CloudKitManager
    @Environment(\.dismiss) private var dismiss
    @State private var showingDeleteAllAlert = false
    @State private var showingResetAlert = false
    @State private var contextLengthText = ""
    @State private var topKText = ""
    
    // Thinking mode text fields
    @State private var thinkingContextLengthText = ""
    @State private var thinkingTopKText = ""
    
    // Toggle for showing thinking parameters
    @State private var showThinkingParameters = false
    
    // LMStudio text fields
    @State private var lmstudioMaxTokensText = ""
    
    // Ollama text fields
    @State private var ollamaMaxTokensText = ""
    
    // LMStudio thinking text fields
    @State private var lmstudioThinkingMaxTokensText = ""
    @State private var showLMStudioThinkingParameters = false

    // Ollama thinking text fields
    @State private var ollamaThinkingMaxTokensText = ""
    @State private var showOllamaThinkingParameters = false
    
    @State private var builtInExpanded   = false   // collapsed by default
    @State private var lmStudioExpanded  = false
    @State private var ollamaExpanded    = false
    
    @State private var builtInMode          : ParamMode = .regular
    @State private var lmStudioMode         : ParamMode = .regular
    @State private var ollamaMode           : ParamMode = .regular
    
    // Focus state for keyboard management
    @FocusState private var focusedField: Field?
    
    enum Field: Hashable {
        case systemPrompt
        case thinkingSystemPrompt
        case contextLength
        case topK
        case thinkingContextLength
        case thinkingTopK
        case lmstudioModelName
        case lmstudioSystemPrompt
        case lmstudioMaxTokens
        case lmstudioThinkingSystemPrompt
        case lmstudioThinkingMaxTokens
        case ollamaModelName
        case ollamaSystemPrompt
        case ollamaMaxTokens
        case ollamaThinkingSystemPrompt
        case ollamaThinkingMaxTokens
    }
    
    enum ParamMode: String, CaseIterable, Identifiable {
        case regular  = "Regular"
        case thinking = "Thinking"
        
        var id: Self { self }
    }
    
    var body: some View {
        NavigationView {
            Form {
                // Built-in Model Settings Section
                DisclosureGroup(
                    isExpanded: $builtInExpanded,
                    content: {
                        modePicker(selection: $builtInMode)
                            .padding(.bottom, 4)

                        if builtInMode == .thinking {
                            thinkingModelSettingsContent()
                        } else {
                            modelSettingsContent(for: .builtIn)
                        }
                    },
                    label: {
                        Label("Built-in Model Settings", systemImage: "cpu")
                            .font(.headline)
                            .labelStyle(.titleOnly)
                    }
                )
                
                
                // LM Studio Settings Section
                DisclosureGroup(
                    isExpanded: $lmStudioExpanded,
                    content: {
                        // Model Name - FIRST (above everything)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model Name")
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("e.g., local-model", text: $cloud.lmstudioModelName)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .lmstudioModelName)
                                .submitLabel(.done)
                        }
                        .padding(.bottom, 8)
                        
                        // Regular ↔︎ Thinking switch - SECOND
                        modePicker(selection: $lmStudioMode)
                            .padding(.bottom, 4)

                        // Show the appropriate sub-view - THIRD
                        if lmStudioMode == .thinking {
                            lmstudioThinkingSettingsContent()
                        } else {
                            modelSettingsContent(for: .lmstudio)
                        }
                    },
                    label: {
                        Label("LM Studio Settings", systemImage: "externaldrive")
                            .font(.headline)
                            .labelStyle(.titleOnly)
                    }
                )
                
                
                // Ollama Settings Section
                DisclosureGroup(
                    isExpanded: $ollamaExpanded,
                    content: {
                        // Model Name - FIRST (above everything)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model Name")
                                .bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("e.g., llama3", text: $cloud.ollamaModelName)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .ollamaModelName)
                                .submitLabel(.done)
                        }
                        .padding(.bottom, 8)
                        
                        // Regular ↔︎ Thinking switch - SECOND
                        modePicker(selection: $ollamaMode)
                            .padding(.bottom, 4)

                        // Show the appropriate sub-view - THIRD
                        if ollamaMode == .thinking {
                            ollamaThinkingSettingsContent()
                        } else {
                            modelSettingsContent(for: .ollama)
                        }
                    },
                    label: {
                        Label("Ollama Settings", systemImage: "square.stack.3d.up")
                            .font(.headline)
                            .labelStyle(.titleOnly)
                    }
                )
                
                // Transcription Settings Section
                Section {
                    Toggle("Voice Transcription", isOn: $cloud.transcriptionEnabled)
                } header: {
                    Text("Voice Input")
                } footer: {
                    Text("When disabled, voice transcription features will be hidden and no model downloads will be prompted.")
                        .font(.caption)
                }
                
                // Delete All Conversations Section
                Section {
                    Button {
                        showingDeleteAllAlert = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .foregroundColor(.red)
                            Text("Delete All Conversations")
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                // Keyboard toolbar
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .onDisappear {
                validateAllFields()
            }
        }
        .alert("Delete All Conversations?", isPresented: $showingDeleteAllAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                deleteAllConversations()
            }
        } message: {
            Text("This will permanently delete all conversations. This action cannot be undone.")
        }
        .alert("Reset to Default Settings?", isPresented: $showingResetAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                resetToDefaults()
            }
        } message: {
            Text("This will reset all model parameters to their default values.")
        }
    }
    
    @ViewBuilder
    private func modePicker(selection: Binding<ParamMode>) -> some View {
        Picker("", selection: selection) {
            ForEach(ParamMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)        // gives the clean text-only look
    }
    
    @ViewBuilder
    private func thinkingModelSettingsContent() -> some View {
        // System Prompt
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking System Prompt")
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("System prompt for thinking mode", text: $cloud.thinkingSystemPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...10)
                .focused($focusedField, equals: .thinkingSystemPrompt)
                .submitLabel(.done)
        }
        
        // Context Length
        HStack {
            Text("Context Length")
                .bold()
                .frame(width: 120, alignment: .leading)
            TextField("Context", text: $thinkingContextLengthText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .thinkingContextLength)
                .onAppear {
                    thinkingContextLengthText = String(cloud.thinkingContextValue)
                }
                .onChange(of: thinkingContextLengthText) { _, newValue in
                    if let value = Int(newValue), value >= 256, value <= 128000 {
                        cloud.thinkingContextValue = value
                    }
                }
                .onSubmit {
                    validateThinkingContextLength()
                }
            Text("tokens")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        
        // Temperature
        VStack(alignment: .leading) {
            HStack {
                Text("Temperature")
                    .bold()
                    .frame(width: 120, alignment: .leading)
                Text(String(format: "%.2f", cloud.thinkingTemperatureValue))
                    .frame(width: 50, alignment: .trailing)
                    .foregroundColor(.secondary)
            }
            Slider(value: $cloud.thinkingTemperatureValue, in: 0...2, step: 0.05)
        }
        
        // Top-K
        HStack {
            Text("Top-K")
                .bold()
                .frame(width: 120, alignment: .leading)
            TextField("Top-K", text: $thinkingTopKText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .thinkingTopK)
                .onAppear {
                    thinkingTopKText = String(cloud.thinkingTopKValue)
                }
                .onChange(of: thinkingTopKText) { _, newValue in
                    if let value = Int(newValue), value >= 1, value <= 200 {
                        cloud.thinkingTopKValue = value
                    }
                }
                .onSubmit {
                    validateThinkingTopK()
                }
        }
        
        // Top-P
        VStack(alignment: .leading) {
            HStack {
                Text("Top-P")
                    .bold()
                    .frame(width: 120, alignment: .leading)
                Text(String(format: "%.2f", cloud.thinkingTopPValue))
                    .frame(width: 50, alignment: .trailing)
                    .foregroundColor(.secondary)
            }
            Slider(value: $cloud.thinkingTopPValue, in: 0...1, step: 0.01)
        }
        
        // Reset to Defaults Button
        Button {
            resetThinkingToDefaults()
        } label: {
            HStack {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundColor(.purple)
                Text("Reset Thinking Parameters to Defaults")
                    .foregroundColor(.purple)
            }
        }
    }
    
    @ViewBuilder
    private func modelSettingsContent(for provider: ModelProvider) -> some View {
        switch provider {
        case .builtIn:
            // System Prompt
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt")
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("System prompt", text: $cloud.builtInSystemPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...10)
                    .focused($focusedField, equals: .systemPrompt)
                    .submitLabel(.done)
            }
            
            // Context Length
            HStack {
                Text("Context Length")
                    .bold()
                    .frame(width: 120, alignment: .leading)
                TextField("Context", text: $contextLengthText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .contextLength)
                    .onAppear {
                        contextLengthText = String(cloud.builtInContextValue)
                    }
                    .onChange(of: contextLengthText) { _, newValue in
                        if let value = Int(newValue), value >= 256, value <= 128000 {
                            cloud.builtInContextValue = value
                        }
                    }
                    .onSubmit {
                        validateContextLength()
                    }
                Text("tokens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Temperature
            VStack(alignment: .leading) {
                HStack {
                    Text("Temperature")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    Text(String(format: "%.2f", cloud.builtInTemperatureValue))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                Slider(value: $cloud.builtInTemperatureValue, in: 0...2, step: 0.05)
            }
            
            // Top-K
            HStack {
                Text("Top-K")
                    .bold()
                    .frame(width: 120, alignment: .leading)
                TextField("Top-K", text: $topKText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .keyboardType(.numberPad)
                    .focused($focusedField, equals: .topK)
                    .onAppear {
                        topKText = String(cloud.builtInTopKValue)
                    }
                    .onChange(of: topKText) { _, newValue in
                        if let value = Int(newValue), value >= 1, value <= 200 {
                            cloud.builtInTopKValue = value
                        }
                    }
                    .onSubmit {
                        validateTopK()
                    }
            }
            
            // Top-P
            VStack(alignment: .leading) {
                HStack {
                    Text("Top-P")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    Text(String(format: "%.2f", cloud.builtInTopPValue))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                Slider(value: $cloud.builtInTopPValue, in: 0...1, step: 0.01)
            }
            
            // Reset to Defaults Button
            Button {
                showingResetAlert = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundColor(.blue)
                    Text("Reset to Defaults")
                        .foregroundColor(.blue)
                }
            }
            
        case .lmstudio:
            // System Prompt
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt (optional)")
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Leave empty to use LM Studio's default", text: $cloud.lmstudioSystemPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...10)
                    .focused($focusedField, equals: .lmstudioSystemPrompt)
                    .submitLabel(.done)
            }
            
            // Max Tokens
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Max Tokens", isOn: $cloud.lmstudioMaxTokensEnabled)
                if cloud.lmstudioMaxTokensEnabled {
                    HStack {
                        Text("Max Tokens")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        TextField("Max tokens", text: $lmstudioMaxTokensText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .lmstudioMaxTokens)
                            .onAppear {
                                lmstudioMaxTokensText = String(cloud.lmstudioMaxTokensValue)
                            }
                            .onChange(of: lmstudioMaxTokensText) { _, newValue in
                                if let value = Int(newValue), value >= 1 {
                                    cloud.lmstudioMaxTokensValue = value
                                }
                            }
                    }
                }
            }
            
            // Temperature
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Temperature", isOn: $cloud.lmstudioTemperatureEnabled)
                if cloud.lmstudioTemperatureEnabled {
                    HStack {
                        Text("Temperature")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text(String(format: "%.2f", cloud.lmstudioTemperatureValue))
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $cloud.lmstudioTemperatureValue, in: 0...2, step: 0.05)
                }
            }
            
            // Top-P
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Top-P", isOn: $cloud.lmstudioTopPEnabled)
                if cloud.lmstudioTopPEnabled {
                    HStack {
                        Text("Top-P")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text(String(format: "%.2f", cloud.lmstudioTopPValue))
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $cloud.lmstudioTopPValue, in: 0...1, step: 0.01)
                }
            }
            
            Text("Note: Only enabled parameters will override LM Studio's")
                .font(.caption)
                .foregroundColor(.secondary)
            
        case .ollama:
            // System Prompt
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt (optional)")
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                TextField("Leave empty to use Ollama's default", text: $cloud.ollamaSystemPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...10)
                    .focused($focusedField, equals: .ollamaSystemPrompt)
                    .submitLabel(.done)
            }
            
            // Max Tokens
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Max Tokens", isOn: $cloud.ollamaMaxTokensEnabled)
                if cloud.ollamaMaxTokensEnabled {
                    HStack {
                        Text("Max Tokens")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        TextField("Max tokens", text: $ollamaMaxTokensText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .ollamaMaxTokens)
                            .onAppear {
                                ollamaMaxTokensText = String(cloud.ollamaMaxTokensValue)
                            }
                            .onChange(of: ollamaMaxTokensText) { _, newValue in
                                if let value = Int(newValue), value >= 1 {
                                    cloud.ollamaMaxTokensValue = value
                                }
                            }
                    }
                }
            }
            
            // Temperature
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Temperature", isOn: $cloud.ollamaTemperatureEnabled)
                if cloud.ollamaTemperatureEnabled {
                    HStack {
                        Text("Temperature")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text(String(format: "%.2f", cloud.ollamaTemperatureValue))
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $cloud.ollamaTemperatureValue, in: 0...2, step: 0.05)
                }
            }
            
            // Top-P
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Override Top-P", isOn: $cloud.ollamaTopPEnabled)
                if cloud.ollamaTopPEnabled {
                    HStack {
                        Text("Top-P")
                            .bold()
                            .frame(width: 120, alignment: .leading)
                        Text(String(format: "%.2f", cloud.ollamaTopPValue))
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $cloud.ollamaTopPValue, in: 0...1, step: 0.01)
                }
            }
            
            Text("Note: Only enabled parameters will override Ollama's")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private func lmstudioThinkingSettingsContent() -> some View {
        // System Prompt
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking System Prompt (optional)")
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Leave empty to use LM Studio's default", text: $cloud.lmstudioThinkingSystemPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...10)
                .focused($focusedField, equals: .lmstudioThinkingSystemPrompt)
                .submitLabel(.done)
        }
        
        // Max Tokens
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Max Tokens", isOn: $cloud.lmstudioThinkingMaxTokensEnabled)
            if cloud.lmstudioThinkingMaxTokensEnabled {
                HStack {
                    Text("Max Tokens")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    TextField("Max tokens", text: $lmstudioThinkingMaxTokensText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .lmstudioThinkingMaxTokens)
                        .onAppear {
                            lmstudioThinkingMaxTokensText = String(cloud.lmstudioThinkingMaxTokensValue)
                        }
                        .onChange(of: lmstudioThinkingMaxTokensText) { _, newValue in
                            if let value = Int(newValue), value >= 1 {
                                cloud.lmstudioThinkingMaxTokensValue = value
                            }
                        }
                }
            }
        }
        
        // Temperature
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Temperature", isOn: $cloud.lmstudioThinkingTemperatureEnabled)
            if cloud.lmstudioThinkingTemperatureEnabled {
                HStack {
                    Text("Temperature")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    Text(String(format: "%.2f", cloud.lmstudioThinkingTemperatureValue))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                Slider(value: $cloud.lmstudioThinkingTemperatureValue, in: 0...2, step: 0.05)
            }
        }
        
        // Top-P
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Top-P", isOn: $cloud.lmstudioThinkingTopPEnabled)
            if cloud.lmstudioThinkingTopPEnabled {
                HStack {
                    Text("Top-P")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    Text(String(format: "%.2f", cloud.lmstudioThinkingTopPValue))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                Slider(value: $cloud.lmstudioThinkingTopPValue, in: 0...1, step: 0.01)
            }
        }
        
        Text("Note: Only enabled parameters will override LM Studio's")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func ollamaThinkingSettingsContent() -> some View {
        // System Prompt
        VStack(alignment: .leading, spacing: 8) {
            Text("Thinking System Prompt (optional)")
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Leave empty to use Ollama's default", text: $cloud.ollamaThinkingSystemPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...10)
                .focused($focusedField, equals: .ollamaThinkingSystemPrompt)
                .submitLabel(.done)
        }
        
        // Max Tokens
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Max Tokens", isOn: $cloud.ollamaThinkingMaxTokensEnabled)
            if cloud.ollamaThinkingMaxTokensEnabled {
                HStack {
                    Text("Max Tokens")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    TextField("Max tokens", text: $ollamaThinkingMaxTokensText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .ollamaThinkingMaxTokens)
                        .onAppear {
                            ollamaThinkingMaxTokensText = String(cloud.ollamaThinkingMaxTokensValue)
                        }
                        .onChange(of: ollamaThinkingMaxTokensText) { _, newValue in
                            if let value = Int(newValue), value >= 1 {
                                cloud.ollamaThinkingMaxTokensValue = value
                            }
                        }
                }
            }
        }
        
        // Temperature
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Temperature", isOn: $cloud.ollamaThinkingTemperatureEnabled)
            if cloud.ollamaThinkingTemperatureEnabled {
                HStack {
                    Text("Temperature")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    Text(String(format: "%.2f", cloud.ollamaThinkingTemperatureValue))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                Slider(value: $cloud.ollamaThinkingTemperatureValue, in: 0...2, step: 0.05)
            }
        }
        
        // Top-P
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Override Top-P", isOn: $cloud.ollamaThinkingTopPEnabled)
            if cloud.ollamaThinkingTopPEnabled {
                HStack {
                    Text("Top-P")
                        .bold()
                        .frame(width: 120, alignment: .leading)
                    Text(String(format: "%.2f", cloud.ollamaThinkingTopPValue))
                        .frame(width: 50, alignment: .trailing)
                        .foregroundColor(.secondary)
                }
                Slider(value: $cloud.ollamaThinkingTopPValue, in: 0...1, step: 0.01)
            }
        }
        
        Text("Note: Only enabled parameters will override Ollama's")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    
    private func validateLMStudioThinkingMaxTokens() {
        if let value = Int(lmstudioThinkingMaxTokensText) {
            cloud.lmstudioThinkingMaxTokensValue = max(1, value)
        }
        lmstudioThinkingMaxTokensText = String(cloud.lmstudioThinkingMaxTokensValue)
    }

    private func validateOllamaThinkingMaxTokens() {
        if let value = Int(ollamaThinkingMaxTokensText) {
            cloud.ollamaThinkingMaxTokensValue = max(1, value)
        }
        ollamaThinkingMaxTokensText = String(cloud.ollamaThinkingMaxTokensValue)
    }
    
    private func validateAllFields() {
        validateContextLength()
        validateTopK()
        validateThinkingContextLength()
        validateThinkingTopK()
        validateLMStudioMaxTokens()
        validateOllamaMaxTokens()
        validateLMStudioThinkingMaxTokens()
        validateOllamaThinkingMaxTokens()
    }
    
    private func validateContextLength() {
        if let value = Int(contextLengthText) {
            cloud.builtInContextValue = max(256, min(128000, value))
        }
        contextLengthText = String(cloud.builtInContextValue)
    }
    
    private func validateTopK() {
        if let value = Int(topKText) {
            cloud.builtInTopKValue = max(1, min(200, value))
        }
        topKText = String(cloud.builtInTopKValue)
    }
    
    private func validateThinkingContextLength() {
        if let value = Int(thinkingContextLengthText) {
            cloud.thinkingContextValue = max(256, min(128000, value))
        }
        thinkingContextLengthText = String(cloud.thinkingContextValue)
    }
    
    private func validateThinkingTopK() {
        if let value = Int(thinkingTopKText) {
            cloud.thinkingTopKValue = max(1, min(200, value))
        }
        thinkingTopKText = String(cloud.thinkingTopKValue)
    }
    
    private func validateLMStudioMaxTokens() {
        if let value = Int(lmstudioMaxTokensText) {
            cloud.lmstudioMaxTokensValue = max(1, value)
        }
        lmstudioMaxTokensText = String(cloud.lmstudioMaxTokensValue)
    }
    
    private func validateOllamaMaxTokens() {
        if let value = Int(ollamaMaxTokensText) {
            cloud.ollamaMaxTokensValue = max(1, value)
        }
        ollamaMaxTokensText = String(cloud.ollamaMaxTokensValue)
    }
    
    private func deleteAllConversations() {
        for conversation in cloud.conversations {
            cloud.deleteConversation(conversation)
        }
        //cloud.startNewConversation()
        dismiss()
    }
    
    private func resetToDefaults() {
        cloud.builtInSystemPrompt = "/no_think"
        cloud.builtInContextValue = 16000
        cloud.builtInTemperatureValue = 0.7
        cloud.builtInTopKValue = 20
        cloud.builtInTopPValue = 0.8
        
        contextLengthText = String(cloud.builtInContextValue)
        topKText = String(cloud.builtInTopKValue)
    }
    
    private func resetThinkingToDefaults() {
        cloud.thinkingSystemPrompt = ""
        cloud.thinkingContextValue = 16000
        cloud.thinkingTemperatureValue = 0.6
        cloud.thinkingTopKValue = 20
        cloud.thinkingTopPValue = 0.95
        
        thinkingContextLengthText = String(cloud.thinkingContextValue)
        thinkingTopKText = String(cloud.thinkingTopKValue)
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
    @StateObject private var downloadManager = ModelDownloadManager.shared
    @StateObject private var tts = TTSManager.shared  // Add this
    @State private var messageText = ""
    @State private var showList = false
    @FocusState private var isFocused: Bool
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 0) {
                    if let conv = cloud.currentConversation {
                        MessagesView(conv: conv, waiting: cloud.isWaitingForResponse)
                    }
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
                .onChange(of: cloud.currentConversation?.id) { oldId, newId in
                    if let oldId = oldId, cloud.serverGeneratingConversationId == oldId {
                        cloud.clearGeneratingState()
                    }
                    // Stop TTS when switching conversations
                    tts.stop()
                }
                
                if cloud.connectionStatus != "Connected" || cloud.isOffline {
                    StatusOverlay(
                        status: cloud.isOffline ? "Offline Mode" : cloud.connectionStatus,
                        isOffline: cloud.isOffline
                    )
                }
                
                // Add TTS controls overlay
                if tts.isSpeaking {
                    TTSControlsOverlay()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.spring(), value: tts.isSpeaking)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showList.toggle() } label: {
                        Image("conversation-list")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 27, height: 27)
                    }
                }
                
                // Model selector in the center
                ToolbarItem(placement: .principal) {
                    ModelSelectorView()
                        .environmentObject(cloud)
                }
                
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // New conversation button
                    Button { cloud.startNewConversation() } label: {
                        Image("new-conversation")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 27, height: 27)
                    }
                }
            }
        }
        .sheet(isPresented: $showList) { ConversationList().environmentObject(cloud) }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(cloud)
        }
        .alert("Error", isPresented: Binding(get: { cloud.errorMessage != nil }, set: { _ in cloud.errorMessage = nil })) {
            Button("OK", role: .cancel) { cloud.errorMessage = nil }
        } message: {
            Text(cloud.errorMessage ?? "Unknown error")
        }
        .onAppear {
            Task {
                if CloudKitManager.shared.transcriptionEnabled {
                    await downloadManager.checkModelStatus()
                }
            }
            UIApplication.shared.isIdleTimerDisabled = true
            
            if cloud.isServerGenerating {
                cloud.clearGeneratingState()
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Stop TTS when app goes to background
            tts.stop()
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
        // Check if transcription is enabled first
        // Change this line to use CloudKitManager's value instead of UserDefaults directly
        let transcriptionEnabled = CloudKitManager.shared.transcriptionEnabled
        guard transcriptionEnabled else {
            await MainActor.run {
                isModelReady = false
                isLoading = false
                statusMessage = "Transcription disabled"
            }
            return
        }
        
        // Rest of the method remains the same...
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
    @State private var copied = false
    @State private var showFullAttachment = false
    @StateObject private var tts = TTSManager.shared

    private var bubbleBackground: Color {
        msg.role == "user"
        ? Color(.systemGray5)
        : Color(.systemBackground)
    }

    private var textColour: Color { .primary }

    private var maxWidthFactor: CGFloat {
        msg.role == "assistant" ? 1.00 : 0.75
    }
    
    // Parse message and attachment
    private var parsedContent: (message: String, attachment: String?) {
        if msg.role == "user" {
            if let range = msg.content.range(of: "\n\n[Attached content]:\n") {
                let message = String(msg.content[..<range.lowerBound])
                let attachmentStart = msg.content.index(range.upperBound, offsetBy: 0)
                let attachment = String(msg.content[attachmentStart...])
                return (message, attachment)
            }
        }
        return (msg.displayContent, nil)
    }

    var body: some View {
        HStack {
            if msg.role == "user" { Spacer() }

            VStack(alignment: msg.role == "user" ? .trailing : .leading,
                   spacing: 5) {

                // ── Message text ──
                Group {
                    if msg.role == "assistant" {
                        Markdown(msg.displayContent)
                            .markdownTheme(.basic)
                            .font(.body)
                    } else {
                        Text(parsedContent.message)
                    }
                }
                .foregroundColor(textColour)
                .padding(12)
                .background(bubbleBackground)
                .cornerRadius(16)
                
                // ── Attachment preview (if present) ──
                if let attachmentText = parsedContent.attachment {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showFullAttachment.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "paperclip")
                                    .font(.caption)
                                Text("Attached content")
                                    .font(.caption)
                                Spacer()
                                Image(systemName: showFullAttachment ? "chevron.up" : "chevron.down")
                                    .font(.caption2)
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        
                        if showFullAttachment {
                            Text(attachmentText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                                .lineLimit(nil)
                        } else {
                            Text(attachmentText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 8)
                        }
                    }
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    .frame(maxWidth: UIScreen.main.bounds.width * maxWidthFactor)
                }

                // ── Meta row (timestamp / copy / speak) ──
                HStack(spacing: 10) {
                    if msg.role == "user" {
                        // Only show copy button and timestamp for user messages
                        copyButton
                        timestampText
                    } else {
                        // Show all three for assistant messages
                        timestampText
                        copyButton
                        speakButton
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: UIScreen.main.bounds.width * maxWidthFactor,
                   alignment: msg.role == "user" ? .trailing : .leading)

            if msg.role == "assistant" { Spacer() }
        }
    }
    
    private var timestampText: some View {
        Text(msg.timestamp, style: .time)
    }

    private var copyButton: some View {
        Button(action: copyToClipboard) {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .labelStyle(.iconOnly)
                .transition(.opacity.combined(with: .scale))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut, value: copied)
    }
    
    private var speakButton: some View {
        Button(action: toggleSpeech) {
            Image(systemName: speakerIcon)
                .foregroundColor(tts.currentMessageId == msg.id ? .accentColor : .secondary)
                .animation(.easeInOut, value: tts.currentMessageId == msg.id)
        }
        .buttonStyle(.plain)
    }
    
    private var speakerIcon: String {
        if tts.currentMessageId == msg.id {
            return tts.isPaused ? "speaker.slash.fill" : "speaker.wave.3.fill"
        }
        return "speaker.wave.2.fill"
    }
    
    private func copyToClipboard() {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        UIPasteboard.general.string = msg.displayContent
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
    
    private func toggleSpeech() {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        
        if tts.currentMessageId == msg.id {
            // Currently speaking this message, stop it
            tts.stop()
        } else {
            // Start speaking this message
            tts.speak(text: msg.displayContent, messageId: msg.id)
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

// MARK: Input bar - MODIFIED with Thinking Toggle
struct MessageInput: View {
    @Binding var text: String
    @FocusState var isFocused: Bool
    var disabled: Bool
    @ObservedObject var transcriber: WhisperTranscriber
    @ObservedObject private var downloadManager = ModelDownloadManager.shared
    @EnvironmentObject private var cloud: CloudKitManager
    @StateObject private var attachmentManager = AttachmentManager()
    @State private var showDownloadAlert = false
    @State private var showAttachmentOptions = false // NEW
    @State private var showImagePicker = false // NEW
    @State private var showDocumentPicker = false // NEW
    var send: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            // Show compilation status if compiling AND transcription is enabled
            if downloadManager.isCompiling && cloud.transcriptionEnabled {
                Text("Compiling transcription model for your device... This takes roughly 5 minutes and is done only once (and with each app update)")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            
            // Show attachment preview if present
            if !attachmentManager.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachmentManager.attachments) { attachment in
                            AttachmentPreview(
                                attachment: attachment,
                                onRemove: {
                                    attachmentManager.removeAttachment(id: attachment.id)
                                }
                            )
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(maxHeight: 100)
            }
            
            // ——— Prompt field (full width) ———
            TextField("Type…", text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(disabled || cloud.isServerGenerating)
                .focused($isFocused)
                .onChange(of: disabled) { if $1 { isFocused = false } }
                .padding(.horizontal)
            
            // ——— Buttons row below the field ———
            ZStack {
                // ❶ Centered overlay when recording
                if transcriber.isRecording {
                    Text("Listening…")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                        .transition(.opacity)
                }
                
                HStack(spacing: 8) {
                    // attachment button
                    Button {
                        showAttachmentOptions = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundColor(.black)
                    }
                    .disabled(attachmentManager.isProcessing || disabled || cloud.isServerGenerating)
                                        
                    // Web search toggle button
                    Button {
                        cloud.enableWebSearch.toggle()
                    } label: {
                        Image(cloud.enableWebSearch ? "web-search-on" : "web-search-off")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 27, height: 27)
                    }
                    
                    // Thinking toggle button (only show if thinking is available)
                    if cloud.isThinkingAvailable {
                        Button {
                            cloud.enableThinking.toggle()
                        } label: {
                            Image(cloud.enableThinking ? "thinking-enabled" : "thinking-disabled")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 27, height: 27)
                                }
                                .accessibilityLabel(cloud.enableThinking ? "Thinking mode enabled"
                                                                         : "Thinking mode disabled")
                            }
                    
                    Spacer() // Push other buttons to the right
                    
                    // ——— Stop generation button (when server is generating) ———
                    if cloud.isServerGenerating {
                        Button {
                            if !cloud.isStopRequestInProgress {
                                cloud.requestStopGeneration()
                            }
                        } label: {
                            if cloud.isStopRequestInProgress {
                                // Show progress indicator while stop request is in progress
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                    .scaleEffect(1.3)
                                    .frame(width: 27, height: 27)
                            } else {
                                // Show stop button image
                                Image("stop-generation")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 27, height: 27)
                            }
                        }
                        .disabled(cloud.isStopRequestInProgress)
                    }
                    
                    // ——— Mic/Download button (only supported devices AND transcription enabled) ———
                    if transcriber.isSupported && cloud.transcriptionEnabled {
                        Button {
                            if downloadManager.isModelReady {
                                // Model is ready, use as microphone
                                if !transcriber.isTranscribing && !cloud.isServerGenerating {
                                    transcriber.toggle()
                                }
                            } else if downloadManager.isDownloading || downloadManager.isLoading || downloadManager.isCompiling {
                                // Currently downloading, loading, or compiling, do nothing
                            } else {
                                // Model not downloaded, show confirmation
                                showDownloadAlert = true
                            }
                        } label: {
                            if downloadManager.isModelReady {
                                if transcriber.isTranscribing {
                                    // Transcribing - show spinning circle (keeping as is but black)
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                        .scaleEffect(1.3)
                                        .frame(width: 27, height: 27)
                                } else if transcriber.isRecording {
                                    // Recording - show stop recording image
                                    Image("stop-recording")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 27, height: 27)
                                } else {
                                    // Idle - show microphone image
                                    Image("microphone")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 27, height: 27)
                                }
                            } else if downloadManager.isDownloading {
                                // Download in progress - show progress circle (keeping as is but black)
                                ZStack {
                                    Circle()
                                        .stroke(Color.black.opacity(0.3), lineWidth: 4)
                                        .frame(width: 27, height: 27)
                                    Circle()
                                        .trim(from: 0, to: CGFloat(downloadManager.downloadProgress))
                                        .stroke(Color.black, lineWidth: 4)
                                        .frame(width: 27, height: 27)
                                        .rotationEffect(.degrees(-90))
                                        .animation(.linear, value: downloadManager.downloadProgress)
                                }
                                .frame(width: 27, height: 27)
                            } else if downloadManager.isLoading || downloadManager.isCompiling {
                                // Loading or compiling model - show spinning circle (keeping as is but black)
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                    .scaleEffect(1.3)
                                    .frame(width: 27, height: 27)
                            } else {
                                // Download icon (keeping as is but black)
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundColor(.black)
                                    .font(.system(size: 27))
                                    .frame(width: 27, height: 27)
                            }
                        }
                        .disabled(downloadManager.isDownloading || downloadManager.isLoading || downloadManager.isCompiling || transcriber.isTranscribing || cloud.isServerGenerating)
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
                            Button("Not now", role: .cancel) {
                                downloadManager.statusMessage = "Model not compiled"
                            }
                            Button("Continue") {
                                Task { await downloadManager.loadModel() }
                            }
                        } message: {
                            Text("The voice model needs to be compiled for your device. This is an intensive process that only happens once (and after app updates) and takes roughly 5 minutes. Please keep the app open during this process.")
                        }
                    }

                    // Send button (only show when active)
                    if (!text.isEmpty || attachmentManager.hasAttachments) && !disabled && !cloud.isServerGenerating {
                        Button {
                            sendWithAttachment()
                        } label: {
                            Image("send-active")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 27, height: 27)
                                     }
                                   }
                                 }
                               }
                                .padding(.horizontal)
                                .padding(.bottom, 6)
                            }
                            .background(Color(.systemBackground))
        // When a new transcript arrives, stuff it into the field
        .onReceive(transcriber.$latestTranscript.compactMap { $0 }) { transcript in
            if !cloud.isServerGenerating {
                let hadFocus = isFocused    // was the field already focused?
                text = transcript
                isFocused = hadFocus        // restore previous focus state
            }
        }
        // Reset transcript when starting new recording
        .onChange(of: transcriber.isRecording) { oldValue, newValue in
            if newValue {
                // Clear previous transcript when starting new recording
                transcriber.latestTranscript = nil
            }
        }
        .confirmationDialog("Add Attachment", isPresented: $showAttachmentOptions) {
                    Button("Photo Library") {
                        showImagePicker = true
                    }
                    Button("Files") {
                        showDocumentPicker = true
                    }
                    Button("Cancel", role: .cancel) { }
                }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker { images in
                Task {
                    for (index, image) in images.enumerated() {
                        await attachmentManager.processImage(
                            image,
                            fileName: "Image \(index + 1)"
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker { documents in
                Task {
                    for (url, fileName) in documents {
                        await attachmentManager.processPDF(
                            at: url,
                            fileName: fileName
                        )
                    }
                }
            }
        }
                .onReceive(transcriber.$latestTranscript.compactMap { $0 }) { transcript in
                    if !cloud.isServerGenerating {
                        let hadFocus = isFocused
                        text = transcript
                        isFocused = hadFocus
                    }
                }
                .onChange(of: transcriber.isRecording) { oldValue, newValue in
                    if newValue {
                        transcriber.latestTranscript = nil
                    }
                }
            }
            
    private func sendWithAttachment() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachmentManager.hasAttachments else { return }
        
        cloud.sendMessage(
            trimmed.isEmpty ? "Please analyze the attached content" : trimmed,
            attachmentText: attachmentManager.combinedAttachmentText
        )
        text = ""
        attachmentManager.clearAllAttachments()
        isFocused = false
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
    @State private var showSettings = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Custom header with settings
                VStack(spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("History & Settings")
                                .font(.title2)
                                .bold()
                                .padding(16)
                        }
                        
                        Spacer()
                        
                        Button {
                            showSettings = true
                        } label: {
                            Image("settings")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 26, height: 26)
                                .padding(8)
                                .background(Color(.systemGray6))
                                .clipShape(Circle())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                .background(Color(.systemBackground))
                
                Divider()
                
                // The list content
                List {
                    Section("Recent Conversations") {
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
                .listStyle(InsetGroupedListStyle())
            }
            .navigationBarHidden(true)
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
            .sheet(isPresented: $showSettings) {
                SettingsView()
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


// MARK: - Image Picker
struct ImagePicker: UIViewControllerRepresentable {
    let onImagesPicked: ([UIImage]) -> Void  // Changed to array
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 0  // 0 means unlimited
        
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker
        
        init(_ parent: ImagePicker) {
            self.parent = parent
        }
        
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            
            guard !results.isEmpty else { return }
            
            var images: [UIImage] = []
            let group = DispatchGroup()
            
            for result in results {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
                    if let image = object as? UIImage {
                        images.append(image)
                    }
                    group.leave()
                }
            }
            
            group.notify(queue: .main) {
                self.parent.onImagesPicked(images)
            }
        }
    }
}


struct AttachmentPreview: View {
    let attachment: AttachmentManager.Attachment
    let onRemove: () -> Void
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: attachment.type == .pdf ? "doc.fill" : "photo.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(attachment.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            
            Text(attachment.extractedText)
                .font(.caption)
                .lineLimit(isExpanded ? nil : 3)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
                .onTapGesture {
                    withAnimation {
                        isExpanded.toggle()
                    }
                }
        }
        .frame(width: 250)
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(12)
    }
}


// MARK: - Document Picker
struct DocumentPicker: UIViewControllerRepresentable {
    let onDocumentsPicked: ([(URL, String)]) -> Void  // Include filename
    @Environment(\.dismiss) private var dismiss
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true  // Allow multiple selection
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            var documents: [(URL, String)] = []
            
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                
                do {
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("pdf")
                    
                    try FileManager.default.copyItem(at: url, to: tempURL)
                    let fileName = url.lastPathComponent
                    documents.append((tempURL, fileName))
                } catch {
                    print("Failed to copy PDF: \(error)")
                }
            }
            
            parent.onDocumentsPicked(documents)
            parent.dismiss()
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}


struct ConversationRow: View {
    let conv: Conversation
    let selected: Bool
    
    // First user prompt (or placeholder if none)
    var firstPrompt: String {
        conv.messages.first(where: { $0.role == "user" })?.displayContent ?? "New conversation"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title row
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
            
            // Meta row (only the timestamp now)
            HStack {
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
                         .preferredColorScheme(.light)
        }
    }
}
