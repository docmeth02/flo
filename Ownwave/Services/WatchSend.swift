//
//  WatchSend.swift
//  Ownwave
//

import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Downloads the songs of albums going to the watch, at the watch's bitrate,
/// into an outbox of their own, and hands each to `WatchLink` once it is
/// here. A background URLSession keeps downloading while the app is
/// suspended; a song that cannot be fetched ends its album's send. Main
/// thread only; the session delegates on the main queue.
final class WatchSend: NSObject {
  static let shared = WatchSend()
  static let identifier = "\(Bundle.main.bundleIdentifier ?? "flo").watch-sends"

  struct Job: Codable, Equatable {
    let album: Album
    let song: Song
    let songCount: Int
    let kbps: Int
    var attempts = 0

    var id: String { "\(album.id):\(song.id)" }
    var suffix: String { kbps > 0 ? TranscodingSettings.targetFormat : song.suffix }
  }

  /// Connection breaks retry this often before the album gives up.
  private static let maxAttempts = 3
  private static let jobsURL = URL.applicationSupportDirectory
    .appendingPathComponent("watch-sends.json")
  private static let outbox = URL.applicationSupportDirectory
    .appendingPathComponent("watch-outbox", isDirectory: true)

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.timeoutIntervalForResource = 2 * 3600
    return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
  }()

  private var jobs: [Job]
  private var tasks: [String: URLSessionTask] = [:]
  private var backgroundCompletions: [() -> Void] = []

  override private init() {
    jobs = (try? JSONDecoder().decode([Job].self, from: Data(contentsOf: Self.jobsURL))) ?? []
    super.init()
    // Created at launch, so the events of a relaunch find their delegate.
    resume()
    NotificationCenter.default.addObserver(
      forName: AppPlatform.didBecomeActive, object: nil, queue: .main
    ) { _ in WatchSend.shared.resume() }
  }

  /// The albums still downloading here.
  var albums: [Album] {
    var seen = Set<String>()
    return jobs.map(\.album).filter { seen.insert($0.id).inserted }
  }

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

  func cancel(_ collectionId: String) {
    for job in jobs where job.album.id == collectionId {
      tasks.removeValue(forKey: job.id)?.cancel()
    }
    jobs.removeAll { $0.album.id == collectionId }
    save()
    try? FileManager.default.removeItem(at: Self.outbox.appendingPathComponent(collectionId))
  }

  func cancelAll() {
    tasks.values.forEach { $0.cancel() }
    tasks = [:]
    jobs = []
    save()
    try? FileManager.default.removeItem(at: Self.outbox)
  }

  /// The watch has the file, or will never get it: the outbox copy goes.
  func delivered(_ file: URL) {
    guard file.path.hasPrefix(Self.outbox.path) else { return }
    try? FileManager.default.removeItem(at: file)
  }

  func handleBackgroundEvents(completion: @escaping () -> Void) {
    backgroundCompletions.append(completion)
  }

  // MARK: - Private

  /// Adopts the session's running tasks and starts the jobs without one.
  /// Tasks created in the background are discretionary for good, so new ones
  /// only start while the app is in front.
  private func resume() {
    session.getAllTasks { running in
      DispatchQueue.main.async {
        for task in running {
          guard let id = task.taskDescription, self.jobs.contains(where: { $0.id == id }) else {
            task.cancel()
            continue
          }
          self.tasks[id] = task
        }
        guard !AppPlatform.isInBackground else { return }
        self.jobs.filter { self.tasks[$0.id] == nil }.forEach(self.submit)
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
    task.resume()
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

  private func finished(_ job: Job, file: URL) {
    jobs.removeAll { $0.id == job.id }
    save()
    Self.transfer(
      file, .song, album: job.album, song: job.song, songCount: job.songCount, suffix: job.suffix,
      kbps: job.kbps)
  }

  private func failed(_ job: Job, _ failure: DownloadFailure) {
    tasks[job.id] = nil
    guard failure == .connection, job.attempts + 1 < Self.maxAttempts,
      let index = jobs.firstIndex(where: { $0.id == job.id })
    else { return failSend(job.album.id) }
    jobs[index].attempts += 1
    save()
    if !AppPlatform.isInBackground { submit(jobs[index]) }
  }

  /// The watch's covers are small; a 200 px PNG goes with the songs.
  private func sendCover(of album: Album, songCount: Int) {
    let source = AlbumService.shared.coverURL(albumId: album.id)
    let target = Self.outbox.appendingPathComponent(album.id).appendingPathComponent("cover.png")
    Task.detached(priority: .utility) {
      var file = URL(fileURLWithPath: source)
      if source.hasPrefix("http"), let remote = URL(string: source) {
        guard let (downloaded, _) = try? await URLSession.shared.download(from: remote) else {
          return
        }
        file = downloaded
      }
      guard Self.writeThumbnail(of: file, to: target) else { return }
      await MainActor.run {
        Self.transfer(target, .cover, album: album, songCount: songCount, suffix: "png", kbps: 0)
      }
    }
  }

  private static func writeThumbnail(of file: URL, to target: URL) -> Bool {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 200,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return false }
    try? FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
      let destination = CGImageDestinationCreateWithURL(
        target as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
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
    let target = Self.outbox.appendingPathComponent(job.album.id)
      .appendingPathComponent("\(job.song.id).\(job.suffix)")
    do {
      try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: target)
      try FileManager.default.moveItem(at: location, to: target)
    } catch {
      return failSend(job.album.id)
    }
    finished(job, file: target)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let error, let job = job(of: task), tasks[job.id] === task else { return }
    failed(job, DownloadFailure.classify(error: error))
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completions = backgroundCompletions
    backgroundCompletions = []
    completions.forEach { $0() }
  }
}
