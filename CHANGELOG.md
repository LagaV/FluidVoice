# Changelog

All notable changes to FluidVoice will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.9] - 2026-02-21

### Added
- Live Transcription state tracking to prevent conflicts with other transcription modes
- Intelligent blocking of hotkey transcriptions when Live Transcription is active

### Fixed
- **Live Transcription notch overlay behavior**: Notch overlay now correctly shows for hotkey transcriptions when Live Transcription is paused
- Hotkey transcriptions are now properly blocked when Live Transcription is active (recording or paused)
- Command mode and rewrite mode are now blocked during active Live Transcription sessions
- Improved resource management by preventing concurrent transcription sessions

### Changed
- `suppressNotchOverlay` flag now only suppresses during active Live Transcription recording, not when paused
- Enhanced state management with separate flags for `isLiveTranscriptionActive` and `isLiveTranscriptionRecording`

## [1.5.6] - Previous Release

### Features
- Live Transcription mode with real-time preview
- Archives management with search and load/delete functionality
- Export functionality with multiple formats (Plain Text, Markdown with timestamps, HTML)
- Editable transcription titles with automatic timestamp presets
- Duration tracking that pauses when not actively recording
- Fuzzy duplicate detection to prevent ASR refinement artifacts
- Session persistence and restoration

### Improvements
- Single text editor with inline timestamp rendering
- YAML frontmatter support in markdown exports
- Timestamp metadata in HTML exports for media synchronization
- Load confirmation dialog to prevent accidental data loss
