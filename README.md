# ios-avfaudio-20260302-160722-wdedev

A usable SwiftUI iOS demo that combines:

- **Speech-to-Text**: capture voice and keep transcript text persistently.
- **Text-to-Speech**: read transcript text out loud.
- **Photo Details + Voice**: take/select a photo, extract text details with Vision OCR, and speak those details.

## What Changed

- Transcript is now persisted in local storage (`UserDefaults`) so it stays after listening stops and across relaunches.
- Live transcription no longer wipes previous content; it appends cleanly.
- Redesigned UI into clearer cards: Transcript, Voice Capture, Photo Details, Playback, and Status.
- Added camera/library photo flow and OCR detail extraction.

## Apple Documentation Links Used

- https://developer.apple.com/documentation/speech
- https://developer.apple.com/documentation/speech/sfspeechrecognizer
- https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer
- https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- https://developer.apple.com/documentation/uikit/uiimagepickercontroller

## Run

1. Generate the project with `xcodegen generate`.
2. Open `ios-avfaudio-20260302-160722-wdedev.xcodeproj` in Xcode.
3. Run on a real iPhone for microphone/camera tests.
4. On first run, grant **Microphone**, **Speech Recognition**, and **Camera/Photo Library** permissions.
