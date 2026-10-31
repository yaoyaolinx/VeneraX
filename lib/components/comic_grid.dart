part of 'components.dart';

/// Verdicts of the background tag lookup that lets a blocked *tag* hide a comic
/// in a list, keyed by `sourceKey@comicId`.
///
/// List items rarely carry tags — most sources only send them with the details
/// request — so [isBlocked] alone can only match keywords there. Comics whose
/// tags are unknown are resolved when their tile is actually built, and the
/// verdict is kept here, shared by every grid in the app, so a comic shown in
/// several lists is resolved once and a revisit costs nothing.
final _deepBlockVerdicts = <String, bool>{};

/// Keys with a lookup in flight, so two grids showing the same comic don't
/// request it twice.
final _deepBlockInFlight = <String>{};

/// Upper bound for [_deepBlockVerdicts]; entries are dropped oldest first.
const _deepBlockVerdictLimit = 4000;

String _deepBlockKey(Comic comic) => '${comic.sourceKey}@${comic.id}';

void _rememberDeepBlockVerdict(String key, bool blocked) {
  _deepBlockVerdicts[key] = blocked;
  if (_deepBlockVerdicts.length > _deepBlockVerdictLimit) {
    _deepBlockVerdicts.remove(_deepBlockVerdicts.keys.first);
  }
}

class SliverGridComics extends StatefulWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onTapWithIndex,
    this.onLongPressed,
    this.onLongPressedWithIndex,
    this.selections,
    this.enableHero = true,
    this.enableContextMenu = true,
    this.swipeActionBuilder,
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID, int index)? onTapWithIndex;

  final void Function(Comic, int heroID)? onLongPressed;

  final void Function(Comic, int heroID, int index)? onLongPressedWithIndex;

  final bool enableHero;

  /// Suppresses single-item menus while the host performs batch selection.
  final bool enableContextMenu;

  /// When set, each tile becomes swipeable on mobile. The builder returns the
  /// panes (start = right swipe, end = left swipe) for a given comic, or null
  /// to leave that comic non-swipeable. See [SwipeActionTile].
  final SwipePanes Function(Comic)? swipeActionBuilder;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];

  static int _nextHeroID = 0;

  /// Hero ids are kept per comic instead of being renumbered whenever the
  /// visible list shrinks, which is now a routine event: blocked items drop out
  /// while the list is already on screen.
  final _heroIDByKey = <String, int>{};

  /// Comics of this grid whose tags were already asked for, so a rebuilt tile
  /// doesn't queue a second lookup.
  final _deepBlockRequested = <String>{};

  /// Tag blocking in lists needs the tags a list item usually doesn't carry.
  /// Off by default: on sources that send no tags with the list it costs one
  /// details request per comic.
  bool get _deepBlockEnabled => appdata.settings['deepBlockInList'] == true;

  int _heroIDOf(Comic comic) =>
      _heroIDByKey.putIfAbsent(_deepBlockKey(comic), () => _nextHeroID++);

  void generateHeroID() {
    heroIDs.clear();
    for (var comic in comics) {
      heroIDs.add(_heroIDOf(comic));
    }
  }

  /// Refills [comics] from the widget's list with everything that is blocked
  /// removed: keyword hits and, when deep blocking is on, the tag verdicts that
  /// arrived from the background lookup.
  void _applyFilter() {
    comics.clear();
    for (var comic in widget.comics) {
      if (isBlocked(comic) != null) {
        continue;
      }
      if (_deepBlockEnabled &&
          _deepBlockVerdicts[_deepBlockKey(comic)] == true) {
        continue;
      }
      comics.add(comic);
    }
    generateHeroID();
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    if (!comics.isEqualTo(widget.comics)) {
      _applyFilter();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    _applyFilter();
    HistoryManager().addListener(update);
    LocalFavoritesManager().addListener(update);
    ReadLaterManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(update);
    LocalFavoritesManager().removeListener(update);
    ReadLaterManager().removeListener(update);
    super.dispose();
  }

  void update() {
    setState(_applyFilter);
  }

  /// Called from the tile builder, so only comics the user actually scrolled to
  /// are resolved — a 300-item update list still costs only what is on screen.
  void _onItemBuilt(Comic comic) {
    if (!_deepBlockEnabled) {
      return;
    }
    // A list item that already carries tags was judged by [isBlocked].
    if (comic.tags?.isNotEmpty ?? false) {
      return;
    }
    var key = _deepBlockKey(comic);
    if (_deepBlockVerdicts.containsKey(key) ||
        _deepBlockInFlight.contains(key)) {
      return;
    }
    if (!_deepBlockRequested.add(key)) {
      return;
    }
    // Never start network work from inside a build.
    scheduleMicrotask(() => unawaited(_resolveDeepBlock(comic)));
  }

  /// Resolves [comic]'s tags and remembers whether one of them is blocked.
  ///
  /// A verdict already in [ComicDetailsCache] costs no request; otherwise the
  /// source's own details call is used — the exact one the details page would
  /// have sent — and its result is written back to that cache, so opening the
  /// comic afterwards is instant.
  Future<void> _resolveDeepBlock(Comic comic) async {
    var key = _deepBlockKey(comic);
    if (!_deepBlockInFlight.add(key)) {
      return;
    }
    try {
      var source = ComicSource.find(comic.sourceKey);
      // Local comics and collections have no details request to make.
      if (source == null ||
          source.loadComicInfo == null ||
          !ComicDetailsCache.isCacheable(comic.sourceKey)) {
        return;
      }
      var cached = ComicDetailsCache().find(comic.sourceKey, comic.id);
      if (cached != null) {
        _rememberDeepBlockVerdict(key, blockedTagOf(cached.plainTags) != null);
        _dropBlockedFromList();
        return;
      }
      var res = await source.loadComicInfo!(comic.id);
      if (!res.success) {
        return;
      }
      var details = res.data;
      ComicDetailsCache().update(comic.sourceKey, comic.id, details);
      _rememberDeepBlockVerdict(key, blockedTagOf(details.plainTags) != null);
      _dropBlockedFromList();
    } catch (e) {
      // A failed lookup must never surface as a list error: the comic simply
      // stays visible, and the verdict is remembered so a broken source isn't
      // retried on every rebuild.
      Log.warning('DeepTagBlock', 'Failed to resolve tags for $key: $e');
      _rememberDeepBlockVerdict(key, false);
    } finally {
      _deepBlockInFlight.remove(key);
    }
  }

  /// Rebuilds once after a lookup only when the verdict actually hides
  /// something, so a clean page costs no extra frames.
  void _dropBlockedFromList() {
    if (!mounted || !_deepBlockEnabled) {
      return;
    }
    for (var comic in comics) {
      if (_deepBlockVerdicts[_deepBlockKey(comic)] == true) {
        setState(_applyFilter);
        return;
      }
    }
  }

  /// Shown instead of the grid when a whole batch was blocked: with nothing
  /// built, [SliverGridComics.onLastItemBuild] never fires and the list would
  /// dead-end on an empty page.
  Widget _buildAllBlocked() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
      child: Column(
        children: [
          Icon(Icons.block, size: 40, color: context.colorScheme.outline),
          const SizedBox(height: 8),
          Text(
            'All comics here are blocked'.tl,
            textAlign: TextAlign.center,
            style: ts.s14.withColor(context.colorScheme.outline),
          ),
          if (widget.onLastItemBuild != null)
            TextButton(
              onPressed: () => widget.onLastItemBuild?.call(),
              child: Text('Load more'.tl),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (comics.isEmpty && widget.comics.isNotEmpty) {
      return SliverToBoxAdapter(child: _buildAllBlocked());
    }
    return _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      enableHero: widget.enableHero,
      enableContextMenu: widget.enableContextMenu,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      onTap: widget.onTap,
      onTapWithIndex: widget.onTapWithIndex,
      onLongPressed: widget.onLongPressed,
      onLongPressedWithIndex: widget.onLongPressedWithIndex,
      swipeActionBuilder: widget.swipeActionBuilder,
      onItemBuilt: _onItemBuilt,
    );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.heroIDs,
    this.enableHero = true,
    this.enableContextMenu = true,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onTapWithIndex,
    this.onLongPressed,
    this.onLongPressedWithIndex,
    this.selection,
    this.swipeActionBuilder,
    this.onItemBuilt,
  });

  final List<Comic> comics;

  final List<int> heroIDs;

  final bool enableHero;

  final bool enableContextMenu;

  final Map<Comic, bool>? selection;

  final void Function()? onLastItemBuild;

  /// Called once per built tile; used to resolve tags that the list item itself
  /// doesn't carry.
  final void Function(Comic)? onItemBuilt;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID, int index)? onTapWithIndex;

  final void Function(Comic, int heroID)? onLongPressed;

  final void Function(Comic, int heroID, int index)? onLongPressedWithIndex;

  final SwipePanes Function(Comic)? swipeActionBuilder;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == comics.length - 1) {
          onLastItemBuild?.call();
        }
        onItemBuilt?.call(comics[index]);
        var badge = badgeBuilder?.call(comics[index]);
        var isSelected = selection == null
            ? false
            : selection![comics[index]] ?? false;
        var comic = ComicTile(
          comic: comics[index],
          enableContextMenu: enableContextMenu,
          badge: badge,
          menuOptions: menuBuilder?.call(comics[index]),
          onTap: onTapWithIndex != null
              ? () => onTapWithIndex!(comics[index], heroIDs[index], index)
              : onTap != null
              ? () => onTap!(comics[index], heroIDs[index])
              : null,
          onLongPressed: onLongPressedWithIndex != null
              ? () => onLongPressedWithIndex!(
                  comics[index],
                  heroIDs[index],
                  index,
                )
              : onLongPressed != null
              ? () => onLongPressed!(comics[index], heroIDs[index])
              : null,
          heroID: enableHero ? heroIDs[index] : null,
        );
        Widget tile = comic;
        if (selection != null) {
          tile = AnimatedContainer(
            key: ValueKey(comics[index].id),
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.toOpacity(0.72)
                  : null,
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(4),
            child: comic,
          );
        }
        if (swipeActionBuilder != null && App.isMobile) {
          final current = comics[index];
          final panes = swipeActionBuilder!(current);
          if (panes.start != null || panes.end != null) {
            tile = SwipeActionTile(
              key: ValueKey('swipe-${current.sourceKey}-${current.id}'),
              startPane: panes.start,
              endPane: panes.end,
              child: tile,
            );
          }
        }
        return tile;
      }, childCount: comics.length),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }
}