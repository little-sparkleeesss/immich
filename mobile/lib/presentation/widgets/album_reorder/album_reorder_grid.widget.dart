import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';

/// Interaction mode for the album reorder grid.
enum AlbumReorderInteractionMode { select, reorder }

/// A responsive grid for displaying album assets in custom sort mode.
///
/// Supports two interaction modes:
/// - [AlbumReorderInteractionMode.reorder]: long-press to drag assets into a
///   new order. Tapping an asset (without drag) opens the asset viewer.
/// - [AlbumReorderInteractionMode.select]: tapping an asset toggles it in the
///   multi-select set, matching the existing timeline selection behavior.
class AlbumReorderGrid extends ConsumerStatefulWidget {
  const AlbumReorderGrid({
    required this.assets,
    required this.interactionMode,
    required this.columnCount,
    required this.onClickAsset,
    required this.onMove,
    super.key,
  });

  /// The flat list of assets, already sorted by CRDT position.
  final List<BaseAsset> assets;

  /// Current interaction mode.
  final AlbumReorderInteractionMode interactionMode;

  /// Number of columns in the grid, matching [TimelineConfig.tilesPerRow].
  final int columnCount;

  /// Called when the user taps a tile (without drag).
  /// Receives the tapped asset and the current ordered list (so the
  /// caller can build an asset viewer in the correct order without
  /// relying on any stale page-level list).
  final void Function(BaseAsset asset, List<BaseAsset> orderedAssets) onClickAsset;

  /// Called when the user finishes a drag of a single asset.
  /// Receives the moved asset ID, optional neighbor IDs, and the full ordered list.
  final Future<bool> Function(String assetId, List<String> orderedAssetIds) onMove;

  @override
  ConsumerState<AlbumReorderGrid> createState() => _AlbumReorderGridState();
}

class _AlbumReorderGridState extends ConsumerState<AlbumReorderGrid> with SingleTickerProviderStateMixin {
  /// Mutable ordered list of assets (for optimistic local reorder).
  late List<BaseAsset> _orderedAssets;

  /// Snapshot of asset order before the current drag started (for rollback).
  List<BaseAsset>? _previousOrder;

  bool _isSaving = false;

  /// Index of the tile currently being targeted during drag (for highlighting).
  int? _dragTargetIndex;

  /// The asset currently being dragged (set on accept, used in finalize).
  BaseAsset? _lastDraggedAsset;

  // ---- FLIP animation state ----

  /// GlobalKeys for measuring tile positions and preserving element identity.
  final Map<String, GlobalKey> _tileKeys = {};

  /// Current FLIP translation offsets, keyed by asset heroTag.
  final Map<String, Offset> _pendingFlips = {};

  /// Drives the FLIP transition animation (200ms).
  AnimationController? _flipController;

  // ---- Edge auto-scroll state ----
  // When the user drags a tile into the top/bottom ~12% of the viewport, a
  // periodic timer scrolls the grid so a tile can be moved over long distances
  // without releasing the drag. Mirrors the pattern in TimelineDragRegion.

  /// Inner scroll controller obtained from the NestedScrollView's injected
  /// PrimaryScrollController. Null before first layout or if detached.
  ScrollController? _scrollController;

  /// Inner Scrollable, used to read the viewport RenderBox + dimensions.
  ScrollableState? _scrollable;

  Timer? _autoScrollTimer;

  /// Last pointer global position, refreshed on every onMove. The timer tick
  /// uses it to recompute the target tile as scrolling brings new tiles under
  /// the (possibly stationary) pointer.
  Offset? _lastPointerOffset;

  /// The asset currently being dragged, cached so the timer tick can call
  /// [_moveAsset] without a fresh DragTargetDetails.
  BaseAsset? _activeDragData;

  /// Top/bottom fraction of the viewport that triggers auto-scroll.
  static const double _edgeFraction = 0.12;

  static const Duration _tickInterval = Duration(milliseconds: 50);

  /// Scroll step per tick at the inner edge of the zone (slow crawl).
  static const double _minScrollStep = 120.0;

  /// Scroll step per tick at the very screen edge (fast traverse).
  static const double _maxScrollStep = 320.0;

  @override
  void initState() {
    super.initState();
    _orderedAssets = List.of(widget.assets);

    _flipController = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _flipController!.addListener(_onFlipTick);
    _flipController!.addStatusListener(_onFlipStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The grid lives in a NestedScrollView body, which injects its inner
    // controller via PrimaryScrollController. Grab it (and the inner Scrollable
    // for viewport geometry) so we can drive auto-scroll during a drag.
    _scrollController = PrimaryScrollController.maybeOf(context);
    _scrollable = Scrollable.of(context);
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _flipController?.removeListener(_onFlipTick);
    _flipController?.removeStatusListener(_onFlipStatus);
    _flipController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AlbumReorderGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-sync ordered list when the asset list changes from outside
    if (oldWidget.assets != widget.assets) {
      _orderedAssets = List.of(widget.assets);
      _syncTileKeys();
    }
  }

  /// Removes stale tile keys for assets no longer in the list.
  void _syncTileKeys() {
    final currentTags = _orderedAssets.map((a) => a.heroTag).toSet();
    _tileKeys.keys.where((tag) => !currentTags.contains(tag)).toList().forEach(_tileKeys.remove);
  }

  // ---- Reorder logic ----

  // ---- FLIP animation helpers ----

  /// Captures the global top-left position of every visible tile.
  Map<String, Offset> _snapshotTilePositions() {
    final positions = <String, Offset>{};
    for (final asset in _orderedAssets) {
      final key = _tileKeys[asset.heroTag];
      if (key?.currentContext?.findRenderObject() case final RenderBox box when box.attached) {
        positions[asset.heroTag] = box.localToGlobal(Offset.zero);
      }
    }
    return positions;
  }

  /// Computes FLIP deltas from old to new positions and starts the animation.
  void _computeFlips(Map<String, Offset> oldPositions, Map<String, Offset> newPositions) {
    _pendingFlips.clear();
    bool hasMovement = false;

    for (final asset in _orderedAssets) {
      final tag = asset.heroTag;
      final oldPos = oldPositions[tag];
      final newPos = newPositions[tag];
      if (oldPos == null || newPos == null) continue;

      final delta = Offset(oldPos.dx - newPos.dx, oldPos.dy - newPos.dy);

      // Only animate tiles that moved more than ~0.5 px
      if (delta.distanceSquared > 0.25) {
        _pendingFlips[tag] = delta;
        hasMovement = true;
      }
    }

    if (hasMovement && _flipController != null) {
      _flipController!.forward(from: 0.0);
    }
  }

  /// Returns the current FLIP translation offset for a tile, or zero.
  Offset _getFlipOffset(String heroTag) {
    final delta = _pendingFlips[heroTag];
    if (delta == null || _flipController == null) return Offset.zero;
    final t = _flipController!.value;
    final eased = Curves.easeInOut.transform(t);
    return delta * (1.0 - eased);
  }

  /// Called on every animation tick to rebuild tiles with updated offsets.
  void _onFlipTick() {
    setState(() {});
  }

  /// Cleans up pending flips when the animation completes.
  void _onFlipStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      setState(() {
        _pendingFlips.clear();
      });
    }
  }

  void _moveAsset(BaseAsset asset, int newIndex) {
    final oldIndex = _orderedAssets.indexOf(asset);
    if (oldIndex == -1 || oldIndex == newIndex) return;

    // Cancel any in-progress FLIP so we can start fresh
    if (_flipController?.isAnimating == true) {
      _flipController!.stop();
      _pendingFlips.clear();
    }

    // Save previous order for rollback BEFORE mutating
    _previousOrder ??= List.of(_orderedAssets);

    // FLIP Step 1 (First): snapshot positions before mutation
    final positionsBefore = _snapshotTilePositions();

    setState(() {
      _orderedAssets.removeAt(oldIndex);
      final clamped = newIndex.clamp(0, _orderedAssets.length);
      _orderedAssets.insert(clamped, asset);
    });

    // FLIP Steps 2–4 (Last, Invert, Play): after layout, compute deltas and animate
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final positionsAfter = _snapshotTilePositions();
      _computeFlips(positionsBefore, positionsAfter);
    });
  }

  Future<void> _finalizeReorder() async {
    if (_previousOrder == null) return; // Nothing changed

    final orderedIds = _orderedAssets.map((a) => a.id).toList();

    setState(() => _isSaving = true);

    final movedId = _lastDraggedAsset != null ? _lastDraggedAsset!.id : orderedIds.first;

    try {
      final success = await widget.onMove(movedId, orderedIds);
      if (success && mounted) {
        HapticFeedback.mediumImpact();
      }
      if (!success && mounted) {
        // Rollback with FLIP animation
        final positionsBefore = _snapshotTilePositions();
        setState(() {
          _orderedAssets = _previousOrder!;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final positionsAfter = _snapshotTilePositions();
          _computeFlips(positionsBefore, positionsAfter);
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
      _previousOrder = null;
      _lastDraggedAsset = null;
    }
  }

  void _cancelDrag() {
    _stopAutoScroll();
    _activeDragData = null;
    if (_previousOrder == null || !mounted) return;

    // Cancel any in-progress FLIP
    _flipController?.stop();
    _pendingFlips.clear();

    // Capture positions before rollback
    final positionsBefore = _snapshotTilePositions();

    setState(() {
      _orderedAssets = _previousOrder!;
      _previousOrder = null;
    });

    // FLIP animate back to the original order
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final positionsAfter = _snapshotTilePositions();
      _computeFlips(positionsBefore, positionsAfter);
    });
  }

  // ---- Edge auto-scroll ----

  /// Returns the auto-scroll direction and how far the pointer is into the
  /// edge zone (depth in [0..1], 0 at the inner boundary, 1 at the screen
  /// edge), or null when the pointer is outside both edge zones.
  ({ScrollDirection direction, double depth})? _edgeZone(Offset globalOffset) {
    final ctrl = _scrollController;
    final box = _scrollable?.context.findRenderObject() as RenderBox?;
    if (ctrl == null || !ctrl.hasClients) {
      return null;
    }
    if (box == null || !box.attached) {
      return null;
    }
    final pos = ctrl.position;
    if (!pos.hasViewportDimension) {
      return null;
    }
    final vh = pos.viewportDimension;
    final localDy = box.globalToLocal(globalOffset).dy;
    final edge = vh * _edgeFraction;
    if (localDy < edge) {
      return (direction: ScrollDirection.reverse, depth: (1.0 - (localDy / edge)).clamp(0.0, 1.0));
    } else if (localDy > vh - edge) {
      return (direction: ScrollDirection.forward, depth: ((localDy - (vh - edge)) / edge).clamp(0.0, 1.0));
    }
    return null;
  }

  /// Called from DragTarget onWillAccept/onMove: caches the pointer position
  /// and dragged asset, and starts/stops the auto-scroll timer based on
  /// whether the pointer is in an edge zone.
  void _updateAutoScroll(Offset globalOffset, BaseAsset data) {
    _lastPointerOffset = globalOffset;
    _activeDragData = data;
    if (_edgeZone(globalOffset) != null) {
      _autoScrollTimer ??= Timer.periodic(_tickInterval, _autoScrollTick);
    } else {
      _stopAutoScroll();
    }
  }

  void _autoScrollTick(Timer _) {
    final offset = _lastPointerOffset;
    if (offset == null) {
      _stopAutoScroll();
      return;
    }
    // Recompute the zone every tick: fresh depth + handle leaving the zone or
    // reversing direction without separate state tracking.
    final zone = _edgeZone(offset);
    if (zone == null) {
      _stopAutoScroll();
      return;
    }
    final ctrl = _scrollController;
    if (ctrl == null || !ctrl.hasClients) {
      return;
    }
    final pos = ctrl.position;
    if (!pos.hasViewportDimension) {
      return;
    }

    final step = _minScrollStep + (_maxScrollStep - _minScrollStep) * zone.depth;
    final target = (pos.pixels + (zone.direction == ScrollDirection.forward ? step : -step)).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    // Already at the extent: skip to avoid a busy-spin of no-op animations.
    if ((target - pos.pixels).abs() < 0.5) {
      return;
    }
    unawaited(ctrl.animateTo(target, duration: const Duration(milliseconds: 100), curve: Curves.easeOut));

    // The pointer may be stationary, but scrolling moved new tiles under it.
    // Recompute the nearest tile after layout reflects the new offset.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _lastPointerOffset == null || _activeDragData == null) {
        return;
      }
      final index = _findNearestIndex(_lastPointerOffset!);
      if (index != null && index != _dragTargetIndex) {
        setState(() => _dragTargetIndex = index);
        _moveAsset(_activeDragData!, index);
      }
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  // ---- Build ----

  /// Finds the index of the tile whose center is closest to [globalPosition].
  int? _findNearestIndex(Offset globalPosition) {
    int? nearest;
    double nearestDist = double.infinity;

    for (int i = 0; i < _orderedAssets.length; i++) {
      final key = _tileKeys[_orderedAssets[i].heroTag];
      final renderBox = key?.currentContext?.findRenderObject();
      if (renderBox is RenderBox && renderBox.attached) {
        final center = renderBox.localToGlobal(renderBox.size.center(Offset.zero));
        final dist = (center - globalPosition).distanceSquared;
        if (dist < nearestDist) {
          nearestDist = dist;
          nearest = i;
        }
      }
    }

    // Only return if within a generous acceptance radius (half tile diagonal)
    // This prevents snapping to far-away tiles
    if (nearest != null && nearestDist < 10000) {
      return nearest;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_orderedAssets.isEmpty && !_isSaving) {
      return const Center(child: Text('No assets in this album'));
    }

    final grid = CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(2),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: widget.columnCount,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
              childAspectRatio: 1,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildTile(index),
              childCount: _orderedAssets.length,
              findChildIndexCallback: (Key key) {
                if (key is GlobalKey) {
                  for (int i = 0; i < _orderedAssets.length; i++) {
                    if (_tileKeys[_orderedAssets[i].heroTag] == key) {
                      return i;
                    }
                  }
                }
                return null;
              },
            ),
          ),
        ),
      ],
    );

    return Stack(
      children: [
        // Full-area DragTarget computes the nearest index from pointer position,
        // making the drop zone much more forgiving than per-tile targets.
        DragTarget<BaseAsset>(
          onWillAcceptWithDetails: (details) {
            final index = _findNearestIndex(details.offset);
            if (index != null) {
              _dragTargetIndex = index;
              _moveAsset(details.data, index);
              setState(() {}); // trigger highlight repaint
            }
            _updateAutoScroll(details.offset, details.data);
            return true;
          },
          onMove: (details) {
            _updateAutoScroll(details.offset, details.data);
            final index = _findNearestIndex(details.offset);
            if (index != _dragTargetIndex) {
              setState(() {
                _dragTargetIndex = index;
              });
              if (index != null) {
                _moveAsset(details.data, index);
              }
            }
          },
          onLeave: (_) {
            _stopAutoScroll();
            _activeDragData = null;
            if (_dragTargetIndex != null) {
              setState(() => _dragTargetIndex = null);
            }
          },
          onAcceptWithDetails: (details) {
            _stopAutoScroll();
            _activeDragData = null;
            _lastDraggedAsset = details.data;
            final index = _findNearestIndex(details.offset);
            if (index != null) {
              _moveAsset(details.data, index);
            }
            _dragTargetIndex = null;
            // onDragEnd is unreliable inside a SliverGrid, so trigger
            // the save directly from DragTarget.onAcceptWithDetails.
            _finalizeReorder();
          },
          builder: (context, candidateData, rejectedData) {
            return grid;
          },
        ),
        if (_isSaving)
          Positioned(
            top: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: context.colorScheme.primary.withValues(alpha: 0.9),
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                ),
                child: Text('Saving...', style: TextStyle(color: context.colorScheme.onPrimary, fontSize: 13)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTile(int index) {
    final asset = _orderedAssets[index];
    final key = _tileKeys.putIfAbsent(asset.heroTag, () => GlobalKey());
    final flipOffset = _getFlipOffset(asset.heroTag);
    final isReorderable = widget.interactionMode == AlbumReorderInteractionMode.reorder;

    Widget tile;

    if (!isReorderable) {
      // ---- Select mode ----
      tile = Builder(
        builder: (context) {
          final isMultiSelectEnabled = ref.watch(multiSelectProvider.select((s) => s.isEnabled));
          return GestureDetector(
            onTap: () {
              if (isMultiSelectEnabled) {
                ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset);
              } else {
                widget.onClickAsset(asset, _orderedAssets);
              }
            },
            onLongPress: () => ref.read(multiSelectProvider.notifier).toggleAssetSelection(asset),
            child: ThumbnailTile(asset, heroOffset: 0),
          );
        },
      );
    } else {
      // ---- Reorder mode ----
      tile = LongPressDraggable<BaseAsset>(
        key: ValueKey('drag_${asset.id}'),
        data: asset,
        delay: const Duration(milliseconds: 200),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        onDragStarted: () {
          HapticFeedback.lightImpact();
        },
        onDragEnd: (_) {
          // _finalizeReorder is called from DragTarget.onAcceptWithDetails
          // because onDragEnd is unreliable inside a SliverGrid. Still cancel
          // any auto-scroll as a backstop in case onAccept/onLeave are skipped.
          _stopAutoScroll();
          _activeDragData = null;
        },
        onDraggableCanceled: (_, __) => _cancelDrag(),
        feedback: Transform.translate(
          // Shift feedback so its visual center aligns with the pointer
          // (pointerDragAnchorStrategy places top-left at pointer).
          // Feedback visual size: 140 × 1.05 = 147, half = 73.5.
          offset: const Offset(-73.5, -73.5),
          child: Material(
            elevation: 8,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: Transform.scale(
              scale: 1.05,
              child: SizedBox(width: 140, height: 140, child: _DragFeedbackImage(asset: asset)),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.3, child: ThumbnailTile(asset, heroOffset: 0)),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => widget.onClickAsset(asset, _orderedAssets),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ThumbnailTile(asset, heroOffset: 0),
              if (index == _dragTargetIndex)
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: context.colorScheme.primary, width: 2),
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    color: context.colorScheme.primary.withValues(alpha: 0.1),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    // Wrap with FLIP translation and identity GlobalKey
    if (flipOffset != Offset.zero) {
      tile = Transform.translate(offset: flipOffset, child: tile);
    }

    return SizedBox(key: key, child: tile);
  }
}

// ---- Sub-widgets ----

class _DragFeedbackImage extends StatelessWidget {
  const _DragFeedbackImage({required this.asset});

  final BaseAsset asset;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Image(image: getFullImageProvider(asset), fit: BoxFit.cover),
    );
  }
}
