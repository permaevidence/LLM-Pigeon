# Pigeon Chat

An iOS chat application that connects to a local AI assistant running on your Mac. Features voice input, web search, document analysis, and seamless CloudKit synchronization.

## Overview

Pigeon Chat is the iOS companion to [LLM Pigeon Server](https://github.com/permaevidence/LLM-Pigeon-Server), enabling you to:
- 💬 Chat with AI models running on your Mac
- 🎤 Use voice transcription for hands-free input
- 🔍 Enable web search for real-time information
- 📎 Attach images and PDFs with automatic text extraction
- 🔊 Listen to responses with text-to-speech
- 💭 Toggle "thinking mode" for detailed reasoning
- 📱 Access conversations offline with intelligent caching

## Features

### Core Functionality
- **Real-time sync** via CloudKit with push notifications
- **Offline mode** with local caching for conversations
- **Multiple LLM providers**: Built-in models, LM Studio, and Ollama
- **Advanced parameters**: Configure temperature, context length, top-k, top-p
- **Stop generation**: Interrupt long responses mid-generation

### Voice & Audio
- **Voice input** using on-device WhisperKit transcription (600MB model)
- **Text-to-speech** with language detection and premium voices
- **Hands-free operation** with voice recording button

### Enhanced Input
- **Web search** integration for current information (requires Serper API key on macOS)
- **Image attachments** with OCR text extraction
- **PDF attachments** with automatic text extraction
- **Multi-file support** for batch processing

### Thinking Mode
- **Chain-of-thought reasoning** for complex queries
- **Separate parameters** for thinking vs regular responses
- **Toggle per conversation** for flexibility

## Requirements

- iOS 16.0+
- iPhone 13 or newer (for voice transcription)
- Xcode 14.0+
- Active Apple Developer account
- iCloud account (same as macOS server)
- [LLM Pigeon Server](https://github.com/permaevidence/LLM-Pigeon-Server) running on macOS

## Installation

### 1. Clone the Repository
```bash
git clone https://github.com/permaevidence/LLM-Pigeon.git
cd LLM-Pigeon
```

### 2. Configure CloudKit

**Important**: Use the SAME CloudKit container as your macOS server!

1. Open the project in Xcode
2. Select your development team
3. Update the bundle identifier (e.g., `com.yourcompany.pigeonchat`)
4. The CloudKit container MUST match: `iCloud.com.pigeonchat.pigeonchat`

### 3. Enable Capabilities
In Xcode → Target → Signing & Capabilities:
- **CloudKit** (using shared container)
- **Push Notifications**
- **Background Modes**: Remote notifications

### 4. First Launch
1. Accept terms of service
2. Grant notification permissions
3. (Optional) Download voice model for transcription
4. Ensure macOS server is running

## Usage Guide

### Getting Started
1. **Start the macOS server first** with your chosen LLM
2. **Launch Pigeon Chat** on your iPhone
3. **Verify connection** - check for "Synced ✓" indicator
4. **Start chatting!**

### Model Selection
Tap the model name in the navigation bar to switch between:
- **Built-in models** (Qwen 0.6B to 32B)
- **LM Studio** (custom model names)
- **Ollama** (custom model names)

### Voice Input
1. Tap the microphone button
2. First use: Download 600MB transcription model
3. Speak your message
4. Tap stop when done

### Attachments
1. Tap the **+** button
2. Choose images or PDFs
3. Text is automatically extracted
4. Send with your message

### Web Search
- Toggle the 🔍 button to enable/disable
- Searches are performed on the macOS server
- Results are integrated into AI responses

### Thinking Mode
- Toggle the 💭 button when available
- Enables step-by-step reasoning
- Uses separate model parameters

## Settings

### Model Parameters
Each provider (Built-in, LM Studio, Ollama) has:
- **Regular parameters**: For standard responses
- **Thinking parameters**: For reasoning mode
- System prompts, temperature, context length, top-k/p

### Voice Settings
- Enable/disable transcription
- Download/manage voice model

### Cache Management
- View cache size and conversation count
- Clear local cache when needed
- Automatic offline access

## Troubleshooting

### "Not syncing with macOS"
1. Verify both devices use same iCloud account
2. Check CloudKit container matches
3. Ensure macOS server is running
4. Check network connectivity

### "Voice button not appearing"
- Only available on iPhone 13+
- Check Settings → Voice Transcription is enabled
- Ensure model is downloaded

### "Attachments not processing"
- Grant photo library permissions
- For PDFs: Ensure file access permissions
- Check attachment preview before sending

### "Conversation size limit"
- Each conversation limited to ~800k characters
- Start new conversation when warned
- Old conversations remain in history

## Privacy & Security

- **On-device transcription**: Voice never leaves your phone
- **Local processing**: AI runs on your Mac
- **Private sync**: CloudKit encryption for all data
- **No external servers**: Except optional web search

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing`)
3. Commit changes (`git commit -m 'Add feature'`)
4. Push branch (`git push origin feature/amazing`)
5. Open Pull Request

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) for voice transcription
- [MarkdownUI](https://github.com/gonzalezreal/MarkdownUI) for formatting
- CloudKit for seamless sync
- Vision framework for OCR

## License

MIT License - see LICENSE file for details

## Contact

permaevidence@protonmail.com

Project Link: [https://github.com/permaevidence/LLM-Pigeon](https://github.com/permaevidence/LLM-Pigeon)
