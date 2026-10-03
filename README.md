# flo watch

flo watch is a standalone Apple Watch client for Navidrome. It signs in to your server directly from the watch, streams or plays downloaded music without a phone nearby, and keeps a queue going on its own with on-device smart shuffle built from your listening history.

It requires Navidrome 0.64 or newer, for its new ids, the scrobble history and the OpenSubsonic transcoding and playback report extensions.

It started as a fork of [flo](https://github.com/kepelet/flo), the open source Navidrome client for iPhone by Kelompok Penerbang Walet, and keeps its MIT license. The iPhone app, CarPlay support and the phone-dependent watch companion were removed; what remains is the watch app and the shared networking, caching and playback code it is built on.

To build, open `flo.xcodeproj` in Xcode and run the "flo Watch App" scheme on a watch simulator or device. The "flo watch" scheme wraps the watch app in the small iOS container App Store Connect requires for watch-only apps and is the one to archive for TestFlight.

## Smart shuffle

Your listening history lives on the server, not on the watch. Navidrome keeps one row per counted play for every client you use, and the watch mirrors that log and keeps it current, so a fresh install knows your taste from the first launch and plays from the phone or the web count just as much as plays from the wrist. Only skips stay on the watch, since the server has no notion of them. What you hear counts as a play after half the song or four minutes of listening, whichever comes first, the same rule Navidrome applies itself; seeking ahead does not count.

Play Something builds a mix of fifteen songs that is mostly what you play a lot right now, with recent months weighing more than old ones, and about one song in six from the less played side of the artists and genres you already live in. Keep Playing, when it is on in Settings, takes over when a queue ends: it continues from the last song you heard to the end, stays within that song's genre, explores about a third of the time and drifts slowly along artists you have played together, never jumping genres on its own. Neither mode ever draws at random from the whole library; a song you have just heard, or a different version of it, waits a few hours before it can come back.

Ratings are the explicit lever. Hold the heart on the Now Playing screen to boost a song, keep it out of smart shuffle, or clear the rating; the same two actions are offered as like and dislike in the system Now Playing controls. On Navidrome's five star scale, five and four push a song forward, three changes nothing, two makes it a rare pick and one keeps it out of smart shuffle altogether while leaving it playable from its album. Ratings set in the Navidrome web interface arrive on the watch with the next sync, and ratings set on the watch are sent to the server, also when they were made offline. The heart itself still marks a favourite.

Settings has a Diagnostics screen that shows the server history as the watch sees it, the latest requests with their timing, and the reasons behind the last mix, song by song. Its share button mails the whole log as text, which is the quickest way to describe a problem.
