# Pigeon Chat

An iOS chat application built with SwiftUI and CloudKit that enables conversations with an AI assistant. The app features real-time synchronization across devices using CloudKit and push notifications.

## Features

- 💬 Real-time chat interface with AI assistant
- ☁️ CloudKit integration for data synchronization
- 📱 Push notification support
- 🔄 Automatic message syncing across devices
- 📝 Markdown support for assistant responses
- 🎨 Modern SwiftUI interface
- 📋 Copy message functionality
- 🗂 Conversation management (create, delete, view history)

## Requirements

- iOS 16.0+
- Xcode 14.0+
- Active Apple Developer account (for CloudKit)
- iCloud account on testing devices

## Setup Instructions

### 1. Clone the Repository
```bash
git clone https://github.com/YOUR_USERNAME/pigeon-chat.git
cd pigeon-chat
```

### 2. Configure CloudKit

1. Open the project in Xcode
2. Select your development team in the project settings
3. Change the bundle identifier to your own (e.g., `com.yourcompany.pigeonchat`)
4. Update the CloudKit container identifier in the code:
   - Find `iCloud.com.pigeonchat.pigeonchat` in `CloudKitManager.swift`
   - Replace with your own container ID: `iCloud.com.yourcompany.yourapp`

### 3. Enable Capabilities in Xcode

1. Select your project in the navigator
2. Select your app target
3. Go to "Signing & Capabilities"
4. Add the following capabilities:
   - **CloudKit**
   - **Push Notifications**
   - **Background Modes** (enable "Remote notifications")

### 4. Configure Entitlements

Update the entitlements file with your CloudKit container:
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.yourcompany.yourapp</string>
</array>
```

### 5. CloudKit Schema

The app will automatically create the required CloudKit schema on first run, but you can manually create it:

**Record Type:** `Conversation`
- Fields:
  - `conversationData` (Bytes)
  - `lastUpdated` (Date/Time)
  - `needsResponse` (Int64)

## Architecture

The app follows MVVM architecture with:
- **CloudKitManager**: Handles all CloudKit operations and serves as the main view model
- **Message & Conversation models**: Codable structs for data representation
- **SwiftUI Views**: Reactive UI components

## Key Components

- **ContentView**: Main chat interface
- **MessagesView**: Scrollable message list with auto-scroll functionality
- **MessageInput**: Text input with send button
- **ConversationList**: Side panel showing all conversations
- **CloudKit Subscriptions**: Automatic updates via push notifications

## Development Notes

### Testing Push Notifications
- Use a real device (simulators don't support push notifications)
- Ensure you're signed into iCloud on the device
- For development, use the Development APNs environment

### Debugging CloudKit
- Check CloudKit Dashboard for your container status
- Monitor console logs for subscription and sync status
- Verify record creation in CloudKit Dashboard

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is available under the MIT License. See the LICENSE file for more info.

## Acknowledgments

- Built with SwiftUI and CloudKit
- Markdown rendering powered by MarkdownUI
- AI assistant integration (requires separate backend setup)

## Contact

Your Name - [@your_twitter](https://twitter.com/your_twitter)

Project Link: [https://github.com/YOUR_USERNAME/pigeon-chat](https://github.com/YOUR_USERNAME/pigeon-chat)