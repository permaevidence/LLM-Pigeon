import SwiftUI
import UIKit
import Foundation
import AVFoundation
import NaturalLanguage

@MainActor
final class TTSManager: NSObject, ObservableObject {
    static let shared = TTSManager()
    
    @Published var isSpeaking = false
    @Published var isPaused = false
    @Published var currentMessageId: UUID?
    @Published var speechRate: Float = 0.53 // Default rate
    
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    
    private override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    // MARK: - Language Detection
    private func detectLanguage(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        
        if let language = recognizer.dominantLanguage {
            return language.rawValue
        }
        
        // Default to device language if detection fails
        return Locale.current.language.languageCode?.identifier ?? "en"
    }
    
    // MARK: - Voice Selection
    private func selectBestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix(language)
        }
        
        // Sort by quality: Premium > Enhanced > Default
        let sortedVoices = voices.sorted { voice1, voice2 in
            let quality1 = voiceQualityScore(voice1)
            let quality2 = voiceQualityScore(voice2)
            return quality1 > quality2
        }
        
        return sortedVoices.first ?? AVSpeechSynthesisVoice(language: language)
    }
    
    private func voiceQualityScore(_ voice: AVSpeechSynthesisVoice) -> Int {
        // Check for quality indicators in voice identifier
        let identifier = voice.identifier.lowercased()
        
        if identifier.contains("premium") {
            return 3
        } else if identifier.contains("enhanced") {
            return 2
        } else if identifier.contains("compact") {
            return 0
        }
        
        // Additional check for voice quality
        switch voice.quality {
        case .premium:
            return 3
        case .enhanced:
            return 2
        case .default:
            return 1
        @unknown default:
            return 1
        }
    }
    
    // MARK: - Playback Control
    func speak(text: String, messageId: UUID) {
        // Stop any current speech
        stop()
        
        // Detect language
        let language = detectLanguage(for: text)
        
        // Select best voice
        guard let voice = selectBestVoice(for: language) else {
            print("[TTS] No voice found for language: \(language)")
            return
        }
        
        print("[TTS] Using voice: \(voice.name) (\(voice.quality == .premium ? "Premium" : voice.quality == .enhanced ? "Enhanced" : "Default"))")
        
        // Create utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = speechRate
        
        // Store current state
        currentUtterance = utterance
        currentMessageId = messageId
        
        // Start speaking
        synthesizer.speak(utterance)
    }
    
    func pauseOrResume() {
        if synthesizer.isSpeaking {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
                isPaused = false
            } else {
                synthesizer.pauseSpeaking(at: .immediate)
                isPaused = true
            }
        }
    }
    
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        currentUtterance = nil
        currentMessageId = nil
        isSpeaking = false
        isPaused = false
    }
    
    func adjustRate(_ rate: Float) {
        speechRate = rate
        
        // If currently speaking, restart with new rate
        if let currentText = currentUtterance?.speechString,
           let messageId = currentMessageId,
           isSpeaking {
            speak(text: currentText, messageId: messageId)
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension TTSManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        isSpeaking = true
        isPaused = false
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
        isPaused = false
        currentMessageId = nil
        currentUtterance = nil
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        isPaused = true
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        isPaused = false
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
        isPaused = false
        currentMessageId = nil
        currentUtterance = nil
    }
}




// MARK: - TTS Controls Overlay
struct TTSControlsOverlay: View {
    @StateObject private var tts = TTSManager.shared
    
    var body: some View {
        VStack {
            Spacer()
            
            // Control buttons only - no speed controls
            HStack(spacing: 24) {
                // Play/Pause button
                Button {
                    tts.pauseOrResume()
                } label: {
                    Image(systemName: tts.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.primary)
                }
                
                // Stop button
                Button {
                    tts.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 25)
                    .fill(.ultraThinMaterial)
                    .shadow(radius: 10)
            )
            .padding(.bottom, 30)
        }
    }
}
