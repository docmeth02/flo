//
//  DownloadSession.swift
//  flo
//

import Combine
import Foundation

/// One song to download into the folder of an album or playlist.
struct DownloadJob: Codable, Equatable {
  /// Collection and media file together: the same song downloaded for an
  /// album and for a playlist is two jobs with two destinations.
  let id: String
  let collectionId: String
  let collectionName: String
  let isPlaylist: Bool
  let playlistIndex: Int
  let song: Song
  /// The file as fetched: the original, or an MP3 at `kbps` when that is > 0.
  let suffix: String
  let kbps: Int
  /// Retries spent on failures that count (see `DownloadFailure`).
  var attempts = 0
  /// The retries are used up or cannot help; shown until the user downloads
  /// the collection again.
  var failed = false
  var retryAt: Date?
  /// When the latest task started, for the log.
  var startedAt: Date?

  var mediaFileId: String { isPlaylist ? song.mediaFileId : song.id }

  /// The jobs for the songs of `collection` that are not in `downloaded`
  /// (media ids), once each: a playlist may hold a song twice.
  static func jobs(
    for collection: Album, isPlaylist: Bool, kbps: Int, downloaded: Set<String>
  ) -> [DownloadJob] {
    var seen = downloaded
    return collection.songs.enumerated().compactMap { index, song in
      let mediaFileId = isPlaylist ? song.mediaFileId : song.id
      guard seen.insert(mediaFileId).inserted else { return nil }
      return DownloadJob(
        id: "\(collection.id):\(mediaFileId)", collectionId: collection.id,
        collectionName: collection.name, isPlaylist: isPlaylist,
        playlistIndex: isPlaylist ? index : -1, song: song,
        suffix: TranscodingSettings.convertedFormat(kbps: kbps) ?? song.suffix, kbps: kbps)
    }
  }
}

enum DownloadProgress {
  /// The share of `batch` (job ids queued together) that is no longer
  /// `pending`.
  static func fraction(batch: Set<String>, pending: Set<String>) -> Double {
    guard !batch.isEmpty else { return 0 }
    return Double(batch.subtracting(pending).count) / Double(batch.count)
  }
}

/// Downloads songs through a background URLSession, which transfers while
/// the app is suspended or was ended by the system; the system relaunches the
/// app in the background to hand the files over. The audio background mode
/// would only keep a foreground download alive while music plays. A
/// force-quit cancels the tasks; the next activation submits the jobs again.
/// Resume data is not kept: a transcode has no byte ranges.
/// Main thread only; the session delegates on the main queue.
final class DownloadSession: NSObject, ObservableObject {
  static let shared = DownloadSession()

  /// In the order they were queued.
  @Published private(set) var jobs: [DownloadJob]
  /// Sent with the collection's id when one of its songs was saved.
  let downloadFinished = PassthroughSubject<String, Never>()
  /// Sent when downloaded collections were deleted, which changes what the
  /// device holds as much as a finished song does.
  let downloadsRemoved = PassthroughSubject<Void, Never>()

  private lazy var session = URLSession.background(
    identifier: "\(Bundle.main.bundleIdentifier ?? "flo").downloads", delegate: self)

  private static let jobFile = JobFile<DownloadJob>(
    fileURL: URL.applicationSupportDirectory.appendingPathComponent("download-jobs.json"),
    label: "download jobs")

  private let store: JobFile<DownloadJob>
  private var tasks: [String: URLSessionTask] = [:]
  private var retries: [String: DispatchWorkItem] = [:]
  /// Job ids queued together per collection, for its progress.
  private var batches: [String: Set<String>]
  private let backgroundEvents = BackgroundEventCompletions()
  /// Nothing is submitted before the session's tasks are known, or a song
  /// still downloading from before the launch would get a second task.
  private var hasReconciled = false
  /// Tasks whose delegate calls have run, so a reconcile knows which
  /// finished tasks still have their delivery queued.
  private var delivered = Set<Int>()

  private init(store: JobFile<DownloadJob> = jobFile) {
    self.store = store
    let jobs = store.load()
    self.jobs = jobs
    batches = Dictionary(grouping: jobs, by: \.collectionId)
      .mapValues { Set($0.map(\.id)) }
    super.init()
    // Created at launch, so the events of a relaunch find their delegate.
    reconcile()

    let center = NotificationCenter.default
    for name: Notification.Name in [AppPlatform.didBecomeActive, .networkBecameOnline] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.reconcile()
      }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: .main) { [weak self] _ in
      self?.cancelAll()
    }
  }

  func isDownloading(collectionId: String) -> Bool {
    jobs.contains { $0.collectionId == collectionId && !$0.failed }
  }

  func hasFailed(collectionId: String) -> Bool {
    jobs.contains { $0.collectionId == collectionId && $0.failed }
  }

  /// Finished songs over the songs queued with them, 0 to 1.
  func progress(collectionId: String) -> Double {
    DownloadProgress.fraction(
      batch: batches[collectionId] ?? [],
      pending: Set(jobs.filter { $0.collectionId == collectionId }.map(\.id)))
  }

  /// Downloads an album, or the missing songs of a downloaded playlist opened
  /// as one. The record comes first: without it the songs never show up in
  /// Downloads, and the cover may fail. A playlist removed since it was
  /// opened gets its record back, built from what the screen shows.
  func enqueue(_ album: Album) {
    let id = album.id
    if !album.isPlaylist || !DownloadStore.hasRecord(collectionId: id) {
      DownloadStore.saveAlbum(album)
      let artId = album.isPlaylist ? (id.hasPrefix("pl-") ? id : "pl-\(id)") : "al-\(id)"
      Self.downloadCover(artId: artId, as: id)
    }
    queueSongs(of: album)
  }

  /// Downloads a playlist with its own cover, which Downloads shows, and the
  /// covers of its tracks' albums.
  func enqueue(_ playlist: Playlist) {
    let id = playlist.id
    DownloadStore.savePlaylist(playlist)
    Self.downloadCover(artId: playlist.artId, as: id)

    // Once per album and one at a time, so they neither time out queued
    // behind each other nor crowd the songs; a stored one stays.
    let albumIds = Set(playlist.songs.map(\.albumId)).filter {
      !$0.isEmpty && DownloadStore.downloadedCoverPath(albumId: $0) == nil
    }
    Task {
      for albumId in albumIds {
        _ = try? await LibraryAPI.downloadCover(
          artId: "al-\(albumId)", as: albumId, overwrite: false)
      }
    }
    queueSongs(of: Album(from: playlist))
  }

  private static func downloadCover(artId: String, as id: String) {
    Task {
      do {
        try await LibraryAPI.downloadCover(artId: artId, as: id)
      } catch {
        debugLog("cover \(id) not saved: \(error.localizedDescription)")
      }
    }
  }

  /// Queues the songs of `collection` that are not on the device yet. A song
  /// queued already keeps its job; failed ones start over at the current
  /// bitrate, and a failed one `collection` does not list (offline a screen
  /// lists only the songs on the device) at the bitrate it had, unless the
  /// song arrived meanwhile, from the iPhone for one.
  private func queueSongs(of collection: Album) {
    let downloaded = DownloadStore.downloadedMediaFileIds(collectionId: collection.id)
    let wanted = DownloadJob.jobs(
      for: collection, isPlaylist: collection.isPlaylist,
      kbps: Int(UserDefaultsManager.downloadBitRate) ?? 0, downloaded: downloaded)
    let continuing = isDownloading(collectionId: collection.id)
    let wantedIds = Set(wanted.map(\.id))

    jobs.removeAll {
      $0.collectionId == collection.id && $0.failed
        && (wantedIds.contains($0.id) || downloaded.contains($0.mediaFileId))
    }
    jobs += wanted.filter { job in !jobs.contains { $0.id == job.id } }
    // A tap does not wait out a retry, and a failed song left unlisted goes
    // again.
    for index in jobs.indices where jobs[index].collectionId == collection.id {
      retries.removeValue(forKey: jobs[index].id)?.cancel()
      jobs[index].retryAt = nil
      if jobs[index].failed {
        jobs[index].failed = false
        jobs[index].attempts = 0
      }
    }
    let queued = jobs.filter { $0.collectionId == collection.id }.map(\.id)
    batches[collection.id] = (continuing ? batches[collection.id] ?? [] : []).union(queued)
    store.save(jobs)

    for job in jobs where job.collectionId == collection.id { submit(job) }
  }

  /// Drops the collection's jobs; a file arriving for one is discarded.
  func cancel(collectionId: String) {
    let ids = jobs.filter { $0.collectionId == collectionId }.map(\.id)
    guard !ids.isEmpty else { return }
    for id in ids {
      tasks.removeValue(forKey: id)?.cancel()
      retries.removeValue(forKey: id)?.cancel()
    }
    jobs.removeAll { $0.collectionId == collectionId }
    batches[collectionId] = nil
    store.save(jobs)
  }

  /// A task keeps the network rule it was created with, so every unfinished
  /// one starts over under the new setting; a transcode starts from zero.
  func cellularAccessChanged() {
    session.getAllTasks { running in
      DispatchQueue.main.async {
        running.forEach { $0.cancel() }
        // Submitted after the snapshot was taken.
        self.tasks.values.forEach { $0.cancel() }
        self.tasks = [:]
        self.jobs.forEach(self.submit)
      }
    }
  }

  func handleBackgroundEvents(completion: @escaping () -> Void) {
    backgroundEvents.hold(completion)
  }

  /// Tasks created in the background are discretionary for good, so they are
  /// only created while the app is in front; a background launch only hands
  /// over finished files, and activation submits the rest.
  private var canSubmit: Bool {
    !AppPlatform.isInBackground
  }

  // The request carries the Subsonic credentials, which wait with the task in
  // the system's transfer store; they stay valid until the password changes
  // or a logout cancels the tasks.
  private func submit(_ job: DownloadJob) {
    guard hasReconciled, tasks[job.id] == nil, !job.failed,
      (job.retryAt ?? .distantPast) <= Date()
    else { return }
    guard canSubmit else {
      return RequestLog.shared.note("download \(job.song.title) waits for the app")
    }
    guard
      var request = LibraryAPI.downloadRequest(
        mediaFileId: job.mediaFileId, kbps: job.kbps)
    else { return markFailed(job, reason: "no server URL") }
    request.allowsCellularAccess = UserDefaultsManager.downloadOverCellular

    let task = session.downloadTask(with: request)
    task.taskDescription = job.id
    tasks[job.id] = task
    // Not saved here: a loop of submits would write the file once per song,
    // and both values only matter while the process lives.
    update(job.id, save: false) {
      $0.startedAt = Date()
      $0.retryAt = nil
    }
    task.resume()
  }

  /// Matches the jobs with the session's tasks: a running task is adopted, a
  /// job without one goes again (uncounted) unless it waits for a retry, and a
  /// task without a job is cancelled.
  private func reconcile() {
    session.getAllTasks { running in
      DispatchQueue.main.async { self.reconcile(running) }
    }
  }

  private func reconcile(_ running: [URLSessionTask]) {
    // A task that finished since the snapshot is left to its delegate calls,
    // which have run or are queued behind this: adopting it would block the
    // job's retry, and a new task would make its file look stale.
    var finishing = Set<String>()
    for task in running {
      guard let id = task.taskDescription, jobs.contains(where: { $0.id == id }),
        tasks[id] == nil || tasks[id] === task
      else {
        task.cancel()
        continue
      }
      if task.state == .completed {
        if !delivered.contains(task.taskIdentifier) { finishing.insert(id) }
      } else {
        tasks[id] = task
      }
    }
    hasReconciled = true
    delivered = []
    for job in jobs where tasks[job.id] == nil && !job.failed && !finishing.contains(job.id) {
      if let retryAt = job.retryAt, retryAt > Date() {
        scheduleRetry(job.id, at: retryAt)
      } else if !saveMovedFile(of: job) {
        submit(job)
      }
    }
  }

  /// A crash between moving a file into place and dropping its job leaves the
  /// file without a record.
  private func saveMovedFile(of job: DownloadJob) -> Bool {
    guard LocalFileManager.shared.fileExists(fileName: destination(of: job)) else { return false }
    finish(job)
    return true
  }

  private func destination(of job: DownloadJob) -> String {
    DownloadStore.downloadPath(
      collectionId: job.collectionId, mediaFileId: job.mediaFileId, suffix: job.suffix)
  }

  private func finish(_ job: DownloadJob) {
    // An unsaved record keeps the job; the next activation finds the file
    // in place and saves it again.
    guard
      DownloadStore.saveDownload(
        albumId: job.collectionId, albumName: job.collectionName, song: job.song,
        suffix: job.suffix, bitRate: job.kbps > 0 ? job.kbps : job.song.bitRate,
        isFromPlaylist: job.isPlaylist, playlistIndex: job.playlistIndex)
    else { return RequestLog.shared.note("download \(job.song.title) not saved") }
    // A record in the stand-in memory store is gone after a relaunch, and the
    // job with it would be too.
    guard !CoreDataManager.shared.isUsingVolatileStore else { return }
    jobs.removeAll { $0.id == job.id }
    if !jobs.contains(where: { $0.collectionId == job.collectionId }) {
      batches[job.collectionId] = nil
    }
    store.save(jobs)
    downloadFinished.send(job.collectionId)
  }

  private func fail(_ job: DownloadJob, _ failure: DownloadFailure) {
    switch failure {
    case .connection:
      // The session waits for a network itself, so a task submitted a while
      // ago goes again at once; one that failed right away waits, or an
      // unreachable host would be asked in a loop.
      let sinceSubmit = job.startedAt.map { Date().timeIntervalSince($0) } ?? .infinity
      if sinceSubmit < DownloadRetry.connectionWait {
        let retryAt = Date().addingTimeInterval(DownloadRetry.connectionWait)
        update(job.id) { $0.retryAt = retryAt }
        scheduleRetry(job.id, at: retryAt)
      } else {
        submit(job)
      }
    case .counted:
      guard let delay = DownloadRetry.delay(afterAttempts: job.attempts) else {
        return markFailed(job, reason: "retries used up")
      }
      let retryAt = Date().addingTimeInterval(delay)
      update(job.id) {
        $0.attempts += 1
        $0.retryAt = retryAt
      }
      RequestLog.shared.note(
        "download retry \(job.song.title) in \(Int(delay)) s, "
          + "\(job.attempts + 1) of \(DownloadRetry.delays.count)")
      scheduleRetry(job.id, at: retryAt)
    case .final:
      markFailed(job, reason: "refused")
    }
  }

  private func markFailed(_ job: DownloadJob, reason: String) {
    update(job.id) {
      $0.failed = true
      $0.retryAt = nil
    }
    RequestLog.shared.note("download failed \(job.song.title): \(reason)")
  }

  private func scheduleRetry(_ id: String, at date: Date) {
    retries[id]?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.retries[id] = nil
      if let job = self.jobs.first(where: { $0.id == id }) { self.submit(job) }
    }
    retries[id] = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, date.timeIntervalSinceNow), execute: work)
  }

  /// Drops every job, at logout and when all downloads are deleted.
  func cancelAll() {
    session.getAllTasks { running in running.forEach { $0.cancel() } }
    tasks.values.forEach { $0.cancel() }
    retries.values.forEach { $0.cancel() }
    tasks = [:]
    retries = [:]
    jobs = []
    batches = [:]
    store.save(jobs)
  }

  private func update(_ id: String, save: Bool = true, _ change: (inout DownloadJob) -> Void) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    change(&jobs[index])
    if save { store.save(jobs) }
  }

  /// The job of a task, nil when it was removed, cancelled or replaced.
  private func job(of task: URLSessionTask) -> DownloadJob? {
    guard let id = task.taskDescription, tasks[id] == nil || tasks[id] === task else { return nil }
    return jobs.first { $0.id == id }
  }

  private func log(_ job: DownloadJob, _ outcome: String) {
    let seconds = job.startedAt.map { String(Int(Date().timeIntervalSince($0))) } ?? "?"
    RequestLog.shared.note(
      "download \(job.song.title) \(outcome) s=\(seconds) attempt=\(job.attempts + 1)")
  }
}

extension DownloadSession: URLSessionDownloadDelegate {
  // The file is gone once this returns, so it is checked and moved here.
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    delivered.insert(downloadTask.taskIdentifier)
    guard let job = job(of: downloadTask) else { return }
    tasks[job.id] = nil

    let response = downloadTask.response as? HTTPURLResponse
    let status = response?.statusCode ?? 0
    let bytes = downloadTask.countOfBytesReceived
    let (failure, subsonicCode) = DownloadFailure.check(response, file: location, bytes: bytes)
    log(job, "status=\(status) bytes=\(bytes)\(subsonicCode.map { " code=\($0)" } ?? "")")
    ConnectivityMonitor.shared.record(response: response, error: nil)

    if let failure { return fail(job, failure) }
    do {
      try LocalFileManager.shared.moveFile(
        source: location, target: LocalFileManager.shared.fileURL(for: destination(of: job)))
      finish(job)
    } catch {
      // Downloading again would not help a full disk.
      markFailed(job, reason: "not moved: \(error.localizedDescription)")
    }
  }

  // A delivered file was handled when it arrived.
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    delivered.insert(task.taskIdentifier)
    guard let error, let job = job(of: task) else { return }
    tasks[job.id] = nil
    log(job, "error=\(error.localizedDescription)")
    fail(job, DownloadFailure.classify(error: error))
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    backgroundEvents.complete()
  }
}
