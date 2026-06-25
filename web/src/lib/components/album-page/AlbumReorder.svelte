<script lang="ts">
  import { flip } from 'svelte/animate';
  import Thumbnail from '$lib/components/assets/thumbnail/Thumbnail.svelte';
  import type { TimelineAsset } from '$lib/managers/timeline-manager/types';
  import { assetMultiSelectManager } from '$lib/managers/asset-multi-select-manager.svelte';
  import { handleMoveAlbumAsset } from '$lib/services/album.service';
  import { mdiDragVertical } from '@mdi/js';
  import { Icon } from '@immich/ui';
  import type { AlbumResponseDto } from '@immich/sdk';
  import { mediaQueryManager } from '$lib/stores/media-query-manager.svelte';
  import { getJustifiedLayoutFromAssets } from '$lib/utils/layout-utils';

  interface Props {
    album: AlbumResponseDto;
    assets: TimelineAsset[];
    interactionMode: 'reorder' | 'select';
    onClickAsset?: (asset: TimelineAsset) => void;
    onReorder?: (assets: TimelineAsset[]) => void;
  }

  let { album, assets, interactionMode, onClickAsset, onReorder }: Props = $props();

  // Match the timeline's rowHeight so the grid layout is visually consistent
  // when switching between date-sort and custom-sort modes.
  const maxMd = $derived(mediaQueryManager.maxMd);
  const rowHeight = $derived(maxMd ? 100 : 235);

  let displayAssets = $state<TimelineAsset[]>([]);
  let isDragging = $state(false);
  let saveInFlight = $state(false);
  let previousOrder: TimelineAsset[] | null = $state<TimelineAsset[] | null>(null);

  // Drag feedback: floating thumbnail that follows the cursor
  let dragCursorX = $state(0);
  let dragCursorY = $state(0);
  let dragSourceWidth = $state(0);
  let dragSourceHeight = $state(0);

  // Justified layout: matches the timeline's row-wrapping behaviour
  let gridElement: HTMLElement | undefined = $state();
  let gridWidth = $state(0);
  let gridIsRtl = $state(false);

  const layoutGeometry = $derived.by(() => {
    if (displayAssets.length === 0 || gridWidth === 0) {
      return null;
    }
    return getJustifiedLayoutFromAssets(displayAssets, {
      rowHeight,
      rowWidth: gridWidth,
      spacing: 2,
      heightTolerance: 0.5,
    });
  });

  const tilePositions = $derived(layoutGeometry ? displayAssets.map((_, i) => layoutGeometry.getPosition(i)) : []);
  const gridHeight = $derived(layoutGeometry ? `${layoutGeometry.containerHeight}px` : '0px');
  const gridMinHeight = $derived(!layoutGeometry && displayAssets.length > 0 ? `${rowHeight}px` : undefined);

  // Cache the grid's writing direction once it mounts. The justified layout
  // emits logical (LTR) `left` values that the browser mirrors via
  // `inset-inline-start` in RTL, so hit-testing must mirror the cursor to
  // match. Direction cannot change mid-drag, so we read it once on bind.
  $effect(() => {
    if (gridElement) {
      gridIsRtl = getComputedStyle(gridElement).direction === 'rtl';
    }
  });

  // Drop target highlight: the tile under the cursor during drag
  let dragTargetId = $state<string | undefined>(undefined);

  const dragState = {
    pointerId: undefined as number | undefined,
    sourceId: undefined as string | undefined,
    startX: 0,
    startY: 0,
    exceededThreshold: false,
    rafPending: false,
    rafId: undefined as number | undefined,
    lastInsertAfter: undefined as boolean | undefined,
  };

  let dragSourceAsset = $derived(
    isDragging && dragState.sourceId ? displayAssets.find((a) => a.id === dragState.sourceId) : undefined,
  );

  const DRAG_THRESHOLD = 5;

  // Sync displayAssets from assets prop.
  // When not dragging: sync both ID changes and order changes.
  // When dragging: only sync ID additions/removals (not order), to avoid
  // clobbering the in-progress drag reorder.
  $effect(() => {
    const newIds = new Set(assets.map((a) => a.id));
    const currentIds = new Set(displayAssets.map((a) => a.id));

    const idsChanged = newIds.size !== currentIds.size || ![...newIds].every((id) => currentIds.has(id));

    if (!isDragging && !idsChanged) {
      // Not dragging, same IDs — sync order if it changed remotely
      const orderChanged = assets.some((a, i) => displayAssets[i]?.id !== a.id);
      if (orderChanged) {
        displayAssets = [...assets];
      }
    } else if (idsChanged) {
      // IDs were added or removed — always sync
      displayAssets = [...assets];
    }
  });

  // --- Pointer-based drag via Svelte action ---
  function dragInitAction(node: HTMLElement, { assetId }: { assetId: string }) {
    const onPointerDown = (e: PointerEvent) => {
      if (node.dataset.interactionMode !== 'reorder') {
        return;
      }
      if (dragState.pointerId !== undefined || saveInFlight) {
        return;
      }

      e.preventDefault();
      node.setPointerCapture(e.pointerId);

      dragState.pointerId = e.pointerId;
      dragState.sourceId = assetId;
      dragState.startX = e.clientX;
      dragState.startY = e.clientY;
      dragState.exceededThreshold = false;
      dragState.lastInsertAfter = undefined;
    };

    const onPointerMove = (e: PointerEvent) => {
      if (e.pointerId !== dragState.pointerId || !dragState.sourceId) {
        return;
      }

      if (!dragState.exceededThreshold) {
        const dx = e.clientX - dragState.startX;
        const dy = e.clientY - dragState.startY;
        if (Math.abs(dx) < DRAG_THRESHOLD && Math.abs(dy) < DRAG_THRESHOLD) {
          return;
        }
        dragState.exceededThreshold = true;
        isDragging = true;
        previousOrder = [...displayAssets];

        // Capture source tile dimensions for the floating ghost.
        const srcRect = node.getBoundingClientRect();
        dragSourceWidth = srcRect.width || rowHeight;
        dragSourceHeight = srcRect.height || rowHeight;
      }

      dragCursorX = e.clientX;
      dragCursorY = e.clientY;
      e.preventDefault();

      // Throttle DOM queries to once per animation frame to avoid
      // layout thrashing on large albums during 60fps pointermove events.
      if (!dragState.rafPending) {
        dragState.rafPending = true;
        dragState.rafId = requestAnimationFrame(() => {
          dragState.rafPending = false;
          dragState.rafId = undefined;
          updateDragReorder(dragCursorX, dragCursorY);
        });
      }
    };

    const onPointerUp = (e: PointerEvent) => {
      if (e.pointerId !== dragState.pointerId) {
        return;
      }
      node.releasePointerCapture(e.pointerId);
      void finishDrag();
    };

    const onPointerCancel = (e: PointerEvent) => {
      if (e.pointerId !== dragState.pointerId) {
        return;
      }
      node.releasePointerCapture(e.pointerId);
      cancelDrag();
    };

    node.addEventListener('pointerdown', onPointerDown);
    node.addEventListener('pointermove', onPointerMove);
    node.addEventListener('pointerup', onPointerUp);
    node.addEventListener('pointercancel', onPointerCancel);

    return {
      destroy() {
        node.removeEventListener('pointerdown', onPointerDown);
        node.removeEventListener('pointermove', onPointerMove);
        node.removeEventListener('pointerup', onPointerUp);
        node.removeEventListener('pointercancel', onPointerCancel);

        // If this tile is the active drag source and gets removed (e.g. asset
        // was externally deleted), abandon the in-flight drag so stale pointer
        // state doesn't block future drags.
        if (dragState.sourceId === assetId) {
          resetDragState();
        }
      },
    };
  }

  function updateDragReorder(clientX: number, clientY: number) {
    if (!dragState.sourceId || !gridElement || !layoutGeometry) {
      return;
    }

    const sourceIndex = displayAssets.findIndex((a) => a.id === dragState.sourceId);
    if (sourceIndex === -1) {
      return;
    }

    // Hit-test against the *final* layout positions (tilePositions), never
    // getBoundingClientRect() on the tiles. The grid container itself isn't
    // animated by `animate:flip` (only the tiles are), so its rect is stable,
    // and the tiles' inline top/left/width/height are already at their final
    // values — flip merely layers a compensating transform on top. Reading the
    // tiles' live rects would return mid-animation positions and reintroduce
    // the reorder feedback loop (oscillation).
    const gridRect = gridElement.getBoundingClientRect();
    const localX = clientX - gridRect.left;
    const localY = clientY - gridRect.top;

    const insertIndex = computeInsertIndex(localX, localY);

    // Highlight the tile adjacent to the insertion gap for visual feedback.
    const afterGap = displayAssets[insertIndex];
    const beforeGap = displayAssets[insertIndex - 1];
    dragTargetId =
      afterGap && afterGap.id !== dragState.sourceId
        ? afterGap.id
        : beforeGap && beforeGap.id !== dragState.sourceId
          ? beforeGap.id
          : undefined;

    // `insertIndex` is a gap index in the full array (0..n). Convert it to a
    // splice position in the array with the source removed, and no-op when the
    // source is already at that gap.
    let target = insertIndex;
    if (sourceIndex < target) {
      target--;
    }
    if (sourceIndex === target) {
      return;
    }

    previousOrder ??= [...displayAssets];

    const next = [...displayAssets];
    const [moved] = next.splice(sourceIndex, 1);
    next.splice(target, 0, moved);
    displayAssets = next;
  }

  // Compute the insertion gap index (0..n) for the cursor at grid-local
  // coordinates, using the *final* justified-layout positions. The array is
  // already in reading order (row-major), so we walk it once: tiles in rows
  // above the cursor are "passed", tiles in rows below are not, and within the
  // cursor's row the horizontal position decides. This correctly handles row
  // boundaries — the end of one row and the start of the next share a single
  // gap index, so the cursor can never "jump" a row — and, because positions
  // are final (not mid-flip), the decision is stable across reorders.
  function computeInsertIndex(localX: number, localY: number): number {
    const n = displayAssets.length;
    if (n === 0) {
      return 0;
    }
    // The layout emits logical (LTR) `left` values; mirror the cursor in RTL so
    // reading-order comparisons stay direction-agnostic.
    const logicalX = gridIsRtl ? gridWidth - localX : localX;
    let insertIndex = 0;
    for (let i = 0; i < n; i++) {
      const p = tilePositions[i];
      if (!p) {
        continue;
      }
      const rowTop = p.top;
      const rowBottom = p.top + p.height;
      if (localY >= rowBottom) {
        // Cursor below this tile's row → past it in reading order.
        insertIndex = i + 1;
        continue;
      }
      if (localY < rowTop) {
        // Cursor above this tile's row → before it; rows are monotonic, so stop.
        break;
      }
      // Cursor within this tile's row band → decide by horizontal position.
      const centerX = p.left + p.width / 2;
      const deadHalf = Math.max(p.width * 0.15, 4);
      if (logicalX > centerX + deadHalf) {
        insertIndex = i + 1;
        dragState.lastInsertAfter = true;
        continue;
      }
      if (logicalX < centerX - deadHalf) {
        dragState.lastInsertAfter = false;
        break;
      }
      // Inside the dead zone → keep the previous direction (hysteresis). Final
      // positions are stable, so this only smooths sub-pixel jitter at a tile's
      // exact centre.
      if (dragState.lastInsertAfter) {
        insertIndex = i + 1;
        continue;
      }
      break;
    }
    return insertIndex;
  }

  function clearDragVisuals() {
    dragState.pointerId = undefined;
    dragState.sourceId = undefined;
    dragState.exceededThreshold = false;
    if (dragState.rafId !== undefined) {
      cancelAnimationFrame(dragState.rafId);
      dragState.rafId = undefined;
    }
    dragState.rafPending = false;
    dragSourceWidth = 0;
    dragSourceHeight = 0;
    dragTargetId = undefined;
  }

  function resetDragState() {
    saveInFlight = false;
    previousOrder = null;
    isDragging = false;
    clearDragVisuals();
  }

  // --- Finish / cancel drag ---
  async function finishDrag() {
    if (!dragState.sourceId) {
      return;
    }

    if (dragState.exceededThreshold) {
      // Apply one last synchronous reorder with the final cursor position.
      // The drag reorder is normally throttled via requestAnimationFrame, so
      // the last pointermove may have scheduled a RAF that hasn't fired yet.
      // Without this sync call, the committed order would be based on a stale
      // cursor position, making the drop point feel displaced from the ghost.
      if (dragState.rafId !== undefined) {
        cancelAnimationFrame(dragState.rafId);
        dragState.rafPending = false;
        dragState.rafId = undefined;
      }
      updateDragReorder(dragCursorX, dragCursorY);

      const movedId = dragState.sourceId;
      const allIds = displayAssets.map((a) => a.id);
      const fallbackOrder = previousOrder;
      // Snapshot the committed order before awaiting so interleaved state
      // changes from a second (blocked) drag can't affect the callback.
      const committedOrder = [...displayAssets];

      // Clear visual drag feedback immediately (thumbnail, highlights) but
      // keep isDragging = true so the sync $effect won't clobber
      // displayAssets with the parent's stale order during the API call.
      clearDragVisuals();
      saveInFlight = true;

      // Save in background, non-blocking for the UI
      const success = await handleMoveAlbumAsset(album.id, {
        assetId: movedId,
        assetIds: allIds,
      });

      // Now complete the drag — update parent state BEFORE releasing
      // isDragging, so the $effect sees the new order when it fires.
      if (!success && fallbackOrder) {
        displayAssets = fallbackOrder; // Triggers FLIP animation back
      } else if (success) {
        onReorder?.(committedOrder);
      }
      isDragging = false;
      saveInFlight = false;
      previousOrder = null;
    } else {
      // tap → click (no threshold exceeded)
      const clickedAsset = displayAssets.find((a) => a.id === dragState.sourceId);
      resetDragState();
      if (clickedAsset) {
        onClickAsset?.(clickedAsset);
      }
    }
  }

  function cancelDrag() {
    if (previousOrder) {
      displayAssets = previousOrder;
    }
    resetDragState();
  }

  // --- Select mode ---
  function toggleSelection(asset: TimelineAsset) {
    if (assetMultiSelectManager.hasSelectedAsset(asset.id)) {
      assetMultiSelectManager.removeAssetFromMultiselectGroup(asset.id);
    } else {
      assetMultiSelectManager.selectAsset(asset);
    }
  }
</script>

<div class="relative">
  {#if isDragging && dragSourceAsset}
    <div
      class="pointer-events-none fixed z-50 overflow-hidden rounded-lg shadow-2xl"
      style="width: {dragSourceWidth}px; height: {dragSourceHeight}px; left: {dragCursorX -
        dragSourceWidth / 2}px; top: {dragCursorY -
        dragSourceHeight / 2}px; transform: scale(1.05);"
    >
      <Thumbnail
        asset={dragSourceAsset}
        readonly={true}
        thumbnailWidth={dragSourceWidth}
        thumbnailHeight={dragSourceHeight}
      />
    </div>
  {/if}

  <div class="p-2">
    <div
      bind:this={gridElement}
      data-reorder-grid
      role="application"
      class="relative"
      class:touch-none={interactionMode === 'reorder'}
      bind:clientWidth={gridWidth}
      style:height={gridHeight}
      style:min-height={gridMinHeight}
      ondragstart={(e) => e.preventDefault()}
    >
      {#each displayAssets as asset, i (asset.id)}
        {@const pos = tilePositions[i]}
        <div
          data-asset-id={asset.id}
          data-reorder-asset-id={asset.id}
          data-interaction-mode={interactionMode}
          use:dragInitAction={{ assetId: asset.id }}
          class="drag-item-container absolute"
          style:top={pos ? pos.top + 'px' : '0px'}
          style:inset-inline-start={pos ? pos.left + 'px' : '0px'}
          style:width={pos ? pos.width + 'px' : '0px'}
          style:height={pos ? pos.height + 'px' : '0px'}
          class:cursor-grab={interactionMode === 'reorder'}
          class:active:cursor-grabbing={interactionMode === 'reorder'}
          class:opacity-40={isDragging && dragState.sourceId !== undefined && dragState.sourceId !== asset.id}
          class:scale-95={isDragging && dragState.sourceId !== undefined && dragState.sourceId !== asset.id}
          class:z-10={dragState.sourceId === asset.id && isDragging}
          class:shadow-xl={dragState.sourceId === asset.id && isDragging}
          animate:flip={{ duration: 150 }}
        >
          {#if interactionMode === 'reorder'}
            <div
              class="pointer-events-none absolute top-1 left-1 z-10 rounded-sm bg-black/40 p-0.5 opacity-0 transition-opacity group-hover:opacity-100"
              class:opacity-100={dragState.sourceId === asset.id}
            >
              <Icon icon={mdiDragVertical} size="16" color="white" />
            </div>
          {/if}

          {#if interactionMode === 'reorder' && asset.id === dragTargetId}
            <div class="pointer-events-none absolute inset-0 z-10 rounded-lg border-2 border-primary bg-primary/10"></div>
          {/if}

          <div class="group drag-image relative size-full overflow-hidden rounded-lg">
            <Thumbnail
              {asset}
              readonly={interactionMode === 'reorder'}
              selected={interactionMode === 'select' ? assetMultiSelectManager.hasSelectedAsset(asset.id) : false}
              thumbnailWidth={pos?.width}
              thumbnailHeight={pos?.height}
              onClick={onClickAsset}
              onSelect={interactionMode === 'select' ? () => toggleSelection(asset) : undefined}
            />
          </div>
        </div>
      {/each}
    </div>
  </div>
</div>

<style>
  .drag-item-container :global(img) {
    -webkit-user-drag: none;
    user-select: none;
  }
</style>
