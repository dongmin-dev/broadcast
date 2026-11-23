# Broadcast

A macOS 27+ menu-bar app that plays a theme tune before Google Calendar meetings,
timed so the music ends exactly when the meeting starts. Personal use for now.

## Requirements

- macOS 27.0 or later
- Xcode 27 (Swift 6)

## Project layout

```
Broadcast.xcodeproj        Xcode project (file-system-synchronized groups: add files
                           under Broadcast/ or BroadcastTests/ without touching the project)
Broadcast/                 App target sources and resources
  App/                     Entry point, AppDelegate, main menu
  StatusBar/               Status item display model, renderer, controller, menu
  Windows/                 WindowCoordinator, Onboarding and Settings windows
  Audio/                   AudioPlayer (bundled sound.mp3)
  Debug/                   Debug-only demo alarm
  Resources/sound.mp3      Theme tune; its length is the alarm lead time
  AppIcon.icon             App icon (Icon Composer)
BroadcastTests/            Unit tests (Swift Testing, hosted in the app)
Config/                    Base.xcconfig, Info.plist additions, secrets template
```

## Secrets

Google OAuth credentials live in `Config/Secrets.xcconfig`, which is git-ignored.
The build works without it (values are empty).

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# then set GOOGLE_CLIENT_ID (and GOOGLE_CLIENT_SECRET if needed)
```

The values are exposed to the app as the Info.plist keys `GoogleClientID` and
`GoogleClientSecret`.

## Build and run

Open `Broadcast.xcodeproj` in Xcode and run the `Broadcast` scheme, or from the
command line:

```sh
xcodebuild -project Broadcast.xcodeproj -scheme Broadcast \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- build
```

The app has no Dock icon and no window at launch; look for the broadcast symbol
in the menu bar. In Debug builds the menu has **Run Demo Alarm**, which runs a
fake 20-second countdown (slow red flash at 8 s, fast at 3 s, then "is live!")
with the music, so the look can be checked without a calendar.

## Test

```sh
xcodebuild -project Broadcast.xcodeproj -scheme Broadcast \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- test
```
