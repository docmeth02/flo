//
//  WatchSend.swift
//  Ownwave
//

import Foundation

/// Downloads the songs of albums going to the watch, at the watch's bitrate,
/// into an outbox of their own, and hands each to `WatchLink` once it is
/// here. A background URLSession keeps downloading while the app is
/// suspended. A job stays until its file was handed over, so a relaunch
/// hands over what arrived meanwhile. Main thread only; the session
/// delegates on the main queue.
final class WatchSend: NSObject {
  static let shared = WatchSend()
  static let identifier = "\(Bundle.main.bundleIdentifier ?? "flo").watch-sends"

  struct Job: Codable {
    let album: Album
    let song: Song
    let songCount: Int
    let kbps: Int
    var attempts = 0
    /// A server failure waits until then, also across launches.
    var retryAt: Date?
    /// Set once the song is in the outbox.
    var downloaded = false

    var id: String { "\(album.id):\(song.id)" }
    var suffix: String { kbps > 0 ? TranscodingSettings.targetFormat : song.suffix }
    var file: URL {
      WatchSend.outbox.appendingPathComponent(album.id).appendingPathComponent("\(song.id).\(suffix)")
    }
  }

  /// A connection break waits this long, uncounted, like DownloadSession's.
  private static let connectionRetry: TimeInterval = 30
  private static let jobsURL = URL.applicationSupportDirectory
    .appendingPathComponent("watch-sends.json")
  fileprivate static let outbox = URL.applicationSupportDirectory
    .appendingPathComponent("watch-outbox", isDirectory: true)

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    // One transcode at a time, so a playing stream is not starved.
    configuration.httpMaximumConnectionsPerHost = 1
    configuration.timeoutIntervalForResource = 2 * 3600
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()

  private var jobs: [Job]
  private var tasks: [String: URLSessionTask] = [:]
  private var backgroundCompletions: [UUID: () -> Void] = [:]

  override private init() {
    jobs = (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: Self.jobsURL))) ?? []
    super.init()
    // Created at launch, so the events of a relaunch find their delegate.
    resume()
    NotificationCenter.default.addObserver(
      forName: AppPlatform.didBecomeActive, object: nil, queue: .main
    ) { _ in WatchSend.shared.resume() }
  }

  /// The albums with songs not handed over yet.
  var albums: [Album] {
    var seen = Set<String>()
    return jobs.map(\.album).filter { seen.insert($0.id).inserted }
  }

  /// Songs of the album not handed over yet.
  func pending(_ collectionId: String) -> Int {
    jobs.filter { $0.album.id == collectionId }.count
  }

  func songCount(_ collectionId: String) -> Int? {
    jobs.first { $0.album.id == collectionId }?.songCount
  }

  func enqueue(_ album: Album, songs: [Song], kbps: Int) {
    var bare = album
    bare.songs = []
    jobs += songs.map { Job(album: bare, song: $0, songCount: songs.count, kbps: kbps) }
    save()
    sendCover(of: bare, songCount: songs.count)
    resume()
  }

  /// Hands every song in the outbox to the link; called once it can take
  /// them.
  func handOver() {
    guard MainActor.assumeIsolated({ WatchLink.shared.canTransfer }) else { return }
    // Lost between a crash and its save: fetched again.
    for job in jobs where job.downloaded && !FileManager.default.fileExists(atPath: job.file.path) {
      update(job.id) { $0.downloaded = false }
    }
    // Out of the jobs before the transfers start, so the progress counts
    // each song once.
    let handed = jobs.filter(\.downloaded)
    if !handed.isEmpty {
      jobs.removeAll(where: \.downloaded)
      save()
    }
    for job in handed {
      Self.transfer(
        job.file, .song, album: job.album, song: job.song, songCount: job.songCount,
        suffix: job.suffix, kbps: job.kbps)
    }
    resume()
  }

  func cancel(_ collectionId: String) {
    for job in jobs where job.album.id == collectionId {
      tasks.removeValue(forKey: job.id)?.cancel()
    }
    jobs.removeAll { $0.album.id == collectionId }
    save()
    try? FileManager.default.removeItem(at: Self.outbox.appendingPathComponent(collectionId))
  }

  /// A logout: the tasks of an earlier launch too, which carry the old
  /// credentials.
  func cancelAll() {
    tasks = [:]
    jobs = []
    save()
    try? FileManager.default.removeItem(at: Self.outbox)
    session.getAllTasks { $0.forEach { $0.cancel() } }
  }

  /// "Download on cellular" changed: running tasks start again with it.
  func cellularAccessChanged() {
    tasks = [:]
    session.getAllTasks { running in
      running.forEach { $0.cancel() }
      DispatchQueue.main.async { self.resume() }
    }
  }

  /// The watch has the file, or will never get it: the outbox copy goes, and
  /// the album's folder once it is empty.
  func delivered(_ file: URL) {
    guard file.path.hasPrefix(Self.outbox.path) else { return }
    let manager = FileManager.default
    try? manager.removeItem(at: file)
    let folder = file.deletingLastPathComponent()
    if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
      try? manager.removeItem(at: folder)
    }
  }

  /// Keeps the system's wake-up until the session delivered its events; they
  /// may have come before it (the session exists from launch), so a deadline
  /// completes it in any case.
  func handleBackgroundEvents(completion: @escaping () -> Void) {
    let id = UUID()
    backgroundCompletions[id] = completion
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      self.backgroundCompletions.removeValue(forKey: id)?()
    }
  }

  // MARK: - Private

  /// Adopts the session's running tasks and starts the jobs without one.
  /// Tasks created in the background are discretionary for good, so new ones
  /// only start while the app is in front.
  private func resume() {
    session.getAllTasks { running in
      DispatchQueue.main.async {
        // Finished and cancelled tasks are left to their delegate calls; a
        // finished one's delivery may still be queued behind this, so its
        // job waits for it rather than downloading again.
        var finishing = Set<String>()
        for task in running {
          guard let id = task.taskDescription,
            self.jobs.contains(where: { $0.id == id && !$0.downloaded })
          else {
            task.cancel()
            continue
          }
          switch task.state {
          case .running, .suspended: if self.tasks[id] == nil { self.tasks[id] = task }
          case .completed: finishing.insert(id)
          default: break
          }
        }
        guard !AppPlatform.isInBackground else { return }
        for job in self.jobs
        where !job.downloaded && self.tasks[job.id] == nil && !finishing.contains(job.id) {
          if let retryAt = job.retryAt, retryAt > Date() {
            self.retry(job, after: retryAt.timeIntervalSinceNow)
          } else {
            self.submit(job)
          }
        }
      }
    }
  }

  private func submit(_ job: Job) {
    guard
      var request = AlbumService.shared.downloadRequest(mediaFileId: job.song.id, kbps: job.kbps)
    else { return failSend(job.album.id) }
    request.allowsCellularAccess = UserDefaultsManager.downloadOverCellular
    let task = session.downloadTask(with: request)
    task.taskDescription = job.id
    tasks[job.id] = task
    if job.retryAt != nil { update(job.id) { $0.retryAt = nil } }
    task.resume()
  }

  private func update(_ id: String, _ change: (inout Job) -> Void) {
    guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
    change(&jobs[index])
    save()
  }

  private func save() {
    do {
      try FileManager.default.createDirectory(
        at: Self.jobsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(jobs).write(to: Self.jobsURL, options: .atomic)
    } catch {
      debugLog("watch send: jobs not saved: \(error)")
    }
  }

  private func job(of task: URLSessionTask) -> Job? {
    jobs.first { $0.id == task.taskDescription }
  }

  /// Hands a file to the link, labelled for this account.
  private static func transfer(
    _ file: URL, _ kind: Link.FileInfo.Kind, album: Album, song: Song? = nil, songCount: Int,
    suffix: String, kbps: Int
  ) {
    guard let key = AuthService.shared.accountKey else { return }
    let info = Link.FileInfo(
      kind: kind, accountKey: key, collectionId: album.id, songCount: songCount, album: album,
      song: song, suffix: suffix, kbps: kbps)
    MainActor.assumeIsolated { WatchLink.shared.transfer(file, info) }
  }

  private func failSend(_ collectionId: String) {
    MainActor.assumeIsolated { WatchLink.shared.failSend(collectionId) }
  }

  /// Retries the job after `delay` unless it is gone or running by then;
  /// in the background the next activation does.
  private func retry(_ job: Job, after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard let job = self.jobs.first(where: { $0.id == job.id }), !job.downloaded,
        self.tasks[job.id] == nil, (job.retryAt ?? .distantPast) <= Date(),
        !AppPlatform.isInBackground
      else { return }
      self.submit(job)
    }
  }

  /// Connection breaks wait and go again uncounted, so a dead zone never
  /// ends a send; server failures retry like DownloadSession's.
  private func failed(_ job: Job, _ failure: DownloadFailure) {
    tasks[job.id] = nil
    switch failure {
    case .connection:
      retry(job, after: Self.connectionRetry)
    case .counted:
      guard let delay = DownloadRetry.delay(afterAttempts: job.attempts) else {
        return failSend(job.album.id)
      }
      update(job.id) {
        $0.attempts += 1
        $0.retryAt = Date().addingTimeInterval(delay)
      }
      retry(job, after: delay)
    case .final:
      failSend(job.album.id)
    }
  }

  /// The watch's covers are small; a 200 px PNG goes with the songs.
  private func sendCover(of album: Album, songCount: Int) {
    let target = Self.outbox.appendingPathComponent(album.id).appendingPathComponent("cover.png")
    Task { @MainActor in
      guard let source = await CoverTint.coverFile(albumId: album.id),
        await Task.detached(priority: .utility, operation: {
          Thumbnail.write(URL(fileURLWithPath: source), to: target, pixels: 200, type: .png)
        }).value
      else { return }
      Self.transfer(target, .cover, album: album, songCount: songCount, suffix: "png", kbps: 0)
    }
  }
}

extension WatchSend: URLSessionDownloadDelegate {
  // The file is gone once this returns, so it is checked and moved here.
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    guard let job = job(of: downloadTask) else { return }
    tasks[job.id] = nil
    let response = downloadTask.response as? HTTPURLResponse
    let isErrorBody = ["json", "xml"].contains { response?.mimeType?.contains($0) == true }
    if let failure = DownloadFailure.classify(
      status: response?.statusCode ?? 0, isErrorBody: isErrorBody, subsonicCode: nil,
      bytes: downloadTask.countOfBytesReceived)
    {
      return failed(job, failure)
    }
    guard (try? LocalFileManager.shared.moveFile(source: location, target: job.file)) != nil
    else { return failSend(job.album.id) }
    update(job.id) { $0.downloaded = true }
    handOver()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // A task replaced since (a cancel and a new submit) has nothing to say.
    guard let error, let job = job(of: task), tasks[job.id] == nil || tasks[job.id] === task
    else { return }
    failed(job, DownloadFailure.classify(error: error))
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completions = backgroundCompletions.values
    backgroundCompletions = [:]
    completions.forEach { $0() }
  }
}
