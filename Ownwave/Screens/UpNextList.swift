//
//  UpNextList.swift
//  Ownwave
//

import CoreData
import SwiftUI
import UIKit

/// The second page: the song playing and the songs after it in play order on
/// one platter, with drag handles to reorder them and a swipe to remove one
/// with Undo. SwiftUI's List shows reorder handles only in edit mode, where
/// swipe actions are off, so the page is a UIKit list of SwiftUI rows. The
/// header and the playing song scroll with the rows, and a pull down at the
/// top returns to the player.
struct UpNextList: View {
  let tint: Color
  /// What the page keeps clear at its top and bottom.
  let insets: EdgeInsets
  /// The list goes back to its top while the player shows.
  let isShown: Bool
  let showPlayer: () -> Void

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    QueueCollection(
      upNext: Array(player.queue.dropFirst(player.activeQueueIdx + 1)), tint: tint,
      palette: palette, scheme: scheme, insets: insets, isShown: isShown, app: app,
      player: player, showPlayer: showPlayer)
  }
}

/// The collection view behind `UpNextList`. Its rows are keyed by the queue
/// entries' object ids, so a snapshot is applied only when the order changes.
private struct QueueCollection: UIViewRepresentable {
  let upNext: [QueueEntity]
  let tint: Color
  let palette: Palette
  let scheme: ColorScheme
  let insets: EdgeInsets
  let isShown: Bool
  let app: AppModel
  let player: PlayerViewModel
  let showPlayer: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> UICollectionView { context.coordinator.makeView() }

  func updateUIView(_ view: UICollectionView, context: Context) {
    context.coordinator.update(self)
  }

  @MainActor
  final class Coordinator: NSObject, UICollectionViewDelegate {
    private enum Section: Int { case top, songs }

    private enum Item: Hashable {
      /// The header, the playing song and the count.
      case top
      case song(NSManagedObjectID)
    }

    private var list: QueueCollection
    private var entries: [NSManagedObjectID: QueueEntity] = [:]
    private weak var collectionView: UICollectionView?
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>?

    init(_ list: QueueCollection) { self.list = list }

    func makeView() -> UICollectionView {
      let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
      view.backgroundColor = .clear
      view.contentInsetAdjustmentBehavior = .never
      view.alwaysBounceVertical = true
      view.showsVerticalScrollIndicator = false
      view.delegate = self
      collectionView = view
      dataSource = makeDataSource(view)
      update(list, animated: false)
      return view
    }

    func update(_ new: QueueCollection, animated: Bool = true) {
      let old = list
      list = new
      guard let view = collectionView, let dataSource else { return }
      let inset = UIEdgeInsets(top: new.insets.top, left: 0, bottom: new.insets.bottom, right: 0)
      if view.contentInset != inset { view.contentInset = inset }
      if old.isShown, !new.isShown {
        view.setContentOffset(CGPoint(x: 0, y: -inset.top), animated: false)
      }
      if old.scheme != new.scheme {
        view.setCollectionViewLayout(makeLayout(), animated: false)
      }
      applyQueue(animated: animated)
      if old.scheme != new.scheme || old.tint != new.tint {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
      }
    }

    /// Shows the queue's order, unless the list shows it already.
    private func applyQueue(animated: Bool) {
      guard let dataSource else { return }
      entries = Dictionary(list.upNext.map { ($0.objectID, $0) }) { first, _ in first }
      let songs = list.upNext.map { Item.song($0.objectID) }
      let shown = dataSource.snapshot()
      if shown.sectionIdentifiers == [.top, .songs],
        shown.itemIdentifiers(inSection: .songs) == songs
      {
        return
      }
      var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
      snapshot.appendSections([.top, .songs])
      snapshot.appendItems([.top], toSection: .top)
      snapshot.appendItems(songs, toSection: .songs)
      dataSource.apply(snapshot, animatingDifferences: animated)
    }

    // MARK: Layout and cells

    private func makeLayout() -> UICollectionViewCompositionalLayout {
      UICollectionViewCompositionalLayout { [weak self] index, environment in
        let isSongs = index == Section.songs.rawValue
        var config = UICollectionLayoutListConfiguration(
          appearance: isSongs ? .insetGrouped : .plain)
        config.backgroundColor = .clear
        config.showsSeparators = isSongs
        if isSongs, let self {
          config.separatorConfiguration.color = UIColor(list.palette.hairline)
          // Under the titles, past the cover.
          config.separatorConfiguration.bottomSeparatorInsets = NSDirectionalEdgeInsets(
            top: 0, leading: UpNextRow.textInset, bottom: 0, trailing: 0)
          config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
          }
        }
        let section = NSCollectionLayoutSection.list(using: config, layoutEnvironment: environment)
        section.contentInsetsReference = .none
        section.contentInsets = NSDirectionalEdgeInsets(
          top: 0, leading: 16, bottom: 0, trailing: 16)
        return section
      }
    }

    private func makeDataSource(_ view: UICollectionView)
      -> UICollectionViewDiffableDataSource<Section, Item>
    {
      let top = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
        [weak self] cell, _, _ in
        guard let self else { return }
        cell.contentConfiguration = UIHostingConfiguration {
          UpNextHeader(tint: self.list.tint, showPlayer: self.list.showPlayer)
            .environmentObject(self.list.player)
            .environment(\.palette, self.list.palette)
        }
        .margins(.all, 0)
        cell.backgroundConfiguration = .clear()
      }
      let song = UICollectionView.CellRegistration<UICollectionViewListCell, NSManagedObjectID> {
        [weak self] cell, _, id in
        guard let self, let entry = entries[id] else { return }
        let palette = list.palette
        cell.contentConfiguration = UIHostingConfiguration {
          UpNextRow(entry: entry, remove: { [weak self] in _ = self?.remove(id) })
            .environment(\.palette, palette)
        }
        .margins(.horizontal, 12)
        .margins(.vertical, 10)
        cell.accessories = [
          .reorder(
            displayed: .always,
            options: .init(tintColor: UIColor(palette.secondary), showsVerticalSeparator: false))
        ]
        cell.configurationUpdateHandler = { cell, state in
          var background = UIBackgroundConfiguration.listCell()
          background.backgroundColor = UIColor(
            state.isHighlighted || state.isSelected ? palette.surface2 : palette.surface)
          cell.backgroundConfiguration = background
        }
      }
      let dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: view) {
        view, indexPath, item in
        switch item {
        case .top: view.dequeueConfiguredReusableCell(using: top, for: indexPath, item: item)
        case .song(let id):
          view.dequeueConfiguredReusableCell(using: song, for: indexPath, item: id)
        }
      }
      dataSource.reorderingHandlers.canReorderItem = { item in item != .top }
      dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
        self?.didReorder(transaction)
      }
      return dataSource
    }

    // MARK: Actions

    /// The entry's index in the play order.
    private func index(of id: NSManagedObjectID) -> Int? {
      list.player.queue.firstIndex { $0.objectID == id }
    }

    private func remove(_ id: NSManagedObjectID) -> Bool {
      let player = list.player
      guard let index = index(of: id), let removed = player.removeFromQueue(at: index) else {
        return false
      }
      list.app.show("Removed from Up Next") { player.undoRemove(removed) }
      return true
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
      guard case .song(let id) = dataSource?.itemIdentifier(for: indexPath) else { return nil }
      let action = UIContextualAction(style: .destructive, title: "Remove") {
        [weak self] _, _, done in
        done(self?.remove(id) ?? false)
      }
      action.image = UIImage(systemName: "minus.circle.fill")
      action.backgroundColor = UIColor(Color.floDestructive)
      return UISwipeActionsConfiguration(actions: [action])
    }

    /// Hands a drag to the queue, both positions in play order; a refused
    /// move puts the rows back in the queue's order.
    private func didReorder(_ transaction: NSDiffableDataSourceTransaction<Section, Item>) {
      guard
        let changes = transaction.sectionTransactions.first(where: {
          $0.sectionIdentifier == .songs
        })?
        .difference
      else { return }
      var from: Int?
      var to: Int?
      for change in changes {
        switch change {
        case .remove(let offset, _, _): from = offset
        case .insert(let offset, _, _): to = offset
        }
      }
      let start = list.player.activeQueueIdx + 1
      if let from, let to, list.player.moveInQueue(from: start + from, to: start + to) { return }
      applyQueue(animated: true)
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ view: UICollectionView, shouldHighlightItemAt indexPath: IndexPath)
      -> Bool
    {
      indexPath.section == Section.songs.rawValue
    }

    func collectionView(_ view: UICollectionView, didSelectItemAt indexPath: IndexPath) {
      view.deselectItem(at: indexPath, animated: true)
      guard case .song(let id) = dataSource?.itemIdentifier(for: indexPath),
        let index = index(of: id)
      else { return }
      list.player.playFromQueue(idx: index)
    }

    /// Rows move among the songs only, never above them.
    func collectionView(
      _ view: UICollectionView,
      targetIndexPathForMoveOfItemFromOriginalIndexPath original: IndexPath,
      atCurrentIndexPath current: IndexPath, toProposedIndexPath proposed: IndexPath
    ) -> IndexPath {
      proposed.section == Section.songs.rawValue
        ? proposed : IndexPath(item: 0, section: Section.songs.rawValue)
    }

    func scrollViewWillEndDragging(
      _ scrollView: UIScrollView, withVelocity velocity: CGPoint,
      targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
      if scrollView.contentOffset.y + scrollView.contentInset.top < -NowPlayingView.threshold {
        list.showPlayer()
      }
    }
  }
}

/// The page's header, the song playing and how many follow.
private struct UpNextHeader: View {
  let tint: Color
  let showPlayer: () -> Void

  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  private var count: Int { max(player.queue.count - player.activeQueueIdx - 1, 0) }

  private var meta: String {
    player.isSmartMix ? player.upNextSource : counted(player.queue.count, "song")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        GlassCircle(systemImage: "chevron.down", action: showPlayer)
        Text("Up Next").font(.sectionTitle).frame(maxWidth: .infinity, alignment: .leading)
        Text(meta).font(.meta).foregroundStyle(palette.secondary)
      }
      if let song = player.nowPlaying { current(song).padding(.top, 16) }
      if count > 0 {
        Text("Next · \(counted(count, "song"))")
          .font(.counter)
          .tracking(0.12 * 11)
          .textCase(.uppercase)
          .foregroundStyle(palette.secondary)
          .padding(.horizontal, 4)
          .padding(.top, 22)
          .padding(.bottom, 8)
      } else {
        Text(
          UserDefaultsManager.keepPlaying
            ? "Nothing up next. Keep Playing will continue with Smart Shuffle."
            : "Nothing up next."
        )
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 38)
      }
    }
  }

  private func current(_ song: QueueEntity) -> some View {
    HStack(spacing: 12) {
      CoverArt(albumId: player.nowPlayingAlbumId, url: player.coverArt, radius: 8)
        .frame(width: 52, height: 52)
      VStack(alignment: .leading, spacing: 1) {
        Text(song.songName ?? "Unknown")
          .font(.rowTitle.weight(.bold))
          .foregroundStyle(tint)
        Text(song.artistName ?? "Unknown")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
        ProgressLine(clock: player.clock, tint: tint).padding(.top, 6)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: player.togglePlayback) {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 20))
          .foregroundStyle(palette.text)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 10)
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .contentShape(Rectangle())
    .onTapGesture(perform: showPlayer)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

/// A song in Up Next: cover, title, and the artist with the mix's short
/// reason.
private struct UpNextRow: View {
  let entry: QueueEntity
  let remove: () -> Void

  /// Where the titles start: the row's margin, the cover and the gap.
  static let textInset: CGFloat = 12 + coverSize + 12
  private static let coverSize: CGFloat = 44

  @ObservedObject private var mixes = RecommendationLog.shared
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 12) {
      CoverArt(albumId: entry.albumId ?? "", radius: 7)
        .frame(width: Self.coverSize, height: Self.coverSize)
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.songName ?? "Unknown").font(.rowTitle.weight(.semibold))
        HStack(spacing: 4) {
          Text(entry.artistName ?? "Unknown").layoutPriority(1)
          if let why = mixes.shownReason(for: entry) {
            Text("·").opacity(0.5)
            ReasonLabel(reason: why)
          }
        }
        .font(.meta)
        .foregroundStyle(palette.secondary)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "Remove", remove)
  }
}
