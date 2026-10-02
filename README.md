# flo watch

flo watch is a standalone Apple Watch client for Navidrome. It signs in to your server directly from the watch, streams or plays downloaded music without a phone nearby, and keeps a queue going on its own with on-device smart shuffle built from your listening history.

It requires Navidrome 0.64 or newer, for its new ids, the scrobble history and the OpenSubsonic transcoding and playback report extensions.

It started as a fork of [flo](https://github.com/kepelet/flo), the open source Navidrome client for iPhone by Kelompok Penerbang Walet, and keeps its MIT license. The iPhone app, CarPlay support and the phone-dependent watch companion were removed; what remains is the watch app and the shared networking, caching and playback code it is built on.

To build, open `flo.xcodeproj` in Xcode and run the "flo Watch App" scheme on a watch simulator or device. The "flo watch" scheme wraps the watch app in the small iOS container App Store Connect requires for watch-only apps and is the one to archive for TestFlight.
