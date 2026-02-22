import Foundation

/// Typed analytics events to avoid typos and enforce a low-cardinality schema.
enum AnalyticsEvent: String {
    // App lifecycle
    case appFirstOpen = "app_first_open"
    case appOpen = "app_open"

    // Consent
    case analyticsConsentChanged = "analytics_consent_changed"

    // Dictation
    case transcriptionCompleted = "transcription_completed"
    case outputDelivered = "output_delivered"
    case postTranscriptionEdit = "post_transcription_edit"

    // Command mode
    case commandModeRunCompleted = "command_mode_run_completed"

    // Write/Rewrite
    case rewriteRunCompleted = "rewrite_run_completed"

    // Meeting transcription
    case meetingTranscriptionCompleted = "meeting_transcription_completed"

    // Live transcription
    case liveTranscriptionStarted = "live_transcription_started"
    case liveTranscriptionPaused = "live_transcription_paused"
    case liveTranscriptionResumed = "live_transcription_resumed"
    case liveTranscriptionCompleted = "live_transcription_completed"
    case liveTranscriptionSaved = "live_transcription_saved"
    case liveTranscriptionLoaded = "live_transcription_loaded"

    // Prompts
    case customPromptUsed = "custom_prompt_used"

    // Errors
    case errorOccurred = "error_occurred"
}

enum AnalyticsMode: String {
    case dictation
    case command
    case rewrite
    case meeting
}

enum AnalyticsOutputMethod: String {
    case typed
    case clipboard
    case historyOnly = "history_only"
}

enum AnalyticsErrorDomain: String {
    case asr
    case llm
    case typing
    case hotkey
    case update
    case other
}
