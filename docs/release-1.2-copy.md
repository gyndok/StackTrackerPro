# StackTrackerPro 1.2 — Release Copy

## App Store "What's New" (paste into App Store Connect)

The biggest update yet — a completely new way to log hands.

• ALL-NEW HAND LOGGER — capture a hand in 5 seconds at the table: tap the card button, pick your hole cards, done. Enrich it later with the full Hand Capture Screen: tap-only entry with live pot tracking, auto-advancing streets, and automatic winner detection at showdown.
• BIG-POT DETECTION — report a stack change after a big pot and the app notices, offering to log the hand with one reply.
• BREAK DEBRIEF — at breaks, the app reviews your stack swings and asks about anything unexplained, so your session story stays complete.
• VOICE NOTES FOR HANDS — dictate what you remember; the transcript attaches to the hand and appears on screen as your reference while you enter the details. Everything stays on your device.
• SHARE ANY HAND — text a formatted hand history (with suit symbols) to a friend straight from the app.
• Level picker, editable stack values, swipe to edit/delete/share hands, keyboard improvements, and dozens of refinements from live-play testing.

## TestFlight "What to Test" (build 16)

Focus areas for this build:
1. HAND LOGGER: log a hand start-to-finish by taps (position → cards → villain → actions → board → showdown). Try mis-tapping a board card and deleting it; change the level mid-entry via the header.
2. DICTATION: tap the mic on the Hand Capture Screen (first use downloads the speech model, one time). Speak the hand as you remember it → "Use Transcript" → the transcript appears as a reference card. Save with or without entering the structured hand.
3. SWING PROMPTS + BREAK DEBRIEF: update your stack in chat after a big change; type "on break" and answer its questions.
4. SHARING: share a saved hand via iMessage — check the text formatting.
5. SWIPE ACTIONS: on the Hands list — share (swipe right), edit/delete (swipe left).
Known: dictation requires a device with Apple Intelligence support; the speech model download needs a network connection once.

## App Review Notes (microphone)

StackTrackerPro 1.2 adds optional voice dictation for the hand logger. The microphone is used only when the user taps the microphone button, to transcribe their spoken description of a poker hand using Apple's on-device SpeechAnalyzer framework. Audio never leaves the device and is not recorded or stored; only the text transcript the user explicitly chooses to keep is saved to their private iCloud data. Usage string: "StackTrackerPro uses the microphone to dictate poker hands for the hand logger."
