# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  std/[algorithm, sequtils, sets, tables],
  eth/common,
  results,
  ./aristo_desc

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

func dup(sTab: Table[VertexID,VertexRef]): Table[VertexID,VertexRef] =
  ## Explicit dup for `VertexRef` values
  for (k,v) in sTab.pairs:
    result[k] = v.dup

func dup(delta: LayerDelta): LayerDelta =
  result = LayerDelta(
    sTab: delta.sTab.dup,            # explicit dup for ref values
    kMap: delta.kMap,
    pAmk: delta.pAmk)

func stackGetLebalOrVoid(db: AristoDbRef; lbl: HashLabel): HashSet[VertexID] =
  # Helper: get next set of vertex IDs from stack.
  for w in db.stack.reversed:
    w.delta.pAmk.withValue(lbl,value):
      return value[]

# ------------------------------------------------------------------------------
# Public getters: lazy value lookup for read only versions
# ------------------------------------------------------------------------------

func lTab*(db: AristoDbRef): Table[LeafTie,VertexID] =
  db.top.final.lTab

func pPrf*(db: AristoDbRef): HashSet[VertexID] =
  db.top.final.pPrf

func vGen*(db: AristoDbRef): seq[VertexID] =
  db.top.final.vGen

func dirty*(db: AristoDbRef): bool =
  db.top.final.dirty

# ------------------------------------------------------------------------------
# Public getters/helpers
# ------------------------------------------------------------------------------

func nLayersVtx*(db: AristoDbRef): int =
  ## Number of vertex entries on the cache layers
  db.stack.mapIt(it.delta.sTab.len).foldl(a + b, db.top.delta.sTab.len)

func nLayersLabel*(db: AristoDbRef): int =
  ## Number of key/label entries on the cache layers
  db.stack.mapIt(it.delta.kMap.len).foldl(a + b, db.top.delta.kMap.len)

func nLayersLebal*(db: AristoDbRef): int =
  ## Number of key/label reverse lookup entries on the cache layers
  db.stack.mapIt(it.delta.pAmk.len).foldl(a + b, db.top.delta.pAmk.len)

# ------------------------------------------------------------------------------
# Public functions: get variants
# ------------------------------------------------------------------------------

proc layersGetVtx*(db: AristoDbRef; vid: VertexID): Result[VertexRef,void] =
  ## Find a vertex on the cache layers. An `ok()` result might contain a
  ## `nil` vertex if it is stored on the cache  that way.
  ##
  if db.top.delta.sTab.hasKey vid:
    return ok(db.top.delta.sTab.getOrVoid vid)

  for w in db.stack.reversed:
    if w.delta.sTab.hasKey vid:
      return ok(w.delta.sTab.getOrVoid vid)

  err()

proc layersGetVtxOrVoid*(db: AristoDbRef; vid: VertexID): VertexRef =
  ## Simplified version of `layersGetVtx()`
  db.layersGetVtx(vid).valueOr: VertexRef(nil)


proc layersGetLabel*(db: AristoDbRef; vid: VertexID): Result[HashLabel,void] =
  ## Find a hash label (containh the `HashKey`) on the cache layers. An
  ## `ok()` result might contain a void hash label if it is stored on the
  ## cache that way.
  ##
  if db.top.delta.kMap.hasKey vid:
    return ok(db.top.delta.kMap.getOrVoid vid)

  for w in db.stack.reversed:
    if w.delta.kMap.hasKey vid:
      return ok(w.delta.kMap.getOrVoid vid)

  err()

proc layersGetlabelOrVoid*(db: AristoDbRef; vid: VertexID): HashLabel =
  ## Simplified version of `layersGetLabel()`
  db.layersGetLabel(vid).valueOr: VOID_HASH_LABEL


proc layersGetKey*(db: AristoDbRef; vid: VertexID): Result[HashKey,void] =
  ## Variant of `layersGetLabel()` for returning the `HashKey` part of the
  ## label only.
  let lbl = db.layersGetLabel(vid).valueOr:
    return err()
  # Note that `lbl.isValid == lbl.key.isValid`
  ok(lbl.key)

proc layersGetKeyOrVoid*(db: AristoDbRef; vid: VertexID): HashKey =
  ## Simplified version of `layersGetKey()`
  db.layersGetKey(vid).valueOr: VOID_HASH_KEY


proc layersGetLebal*(
    db: AristoDbRef;
    lbl: HashLabel;
      ): Result[HashSet[VertexID],void] =
  ## Inverse of `layersGetKey()`. For a given argumnt `lbl`, find all vertex
  ## IDs that have `layersGetLbl()` return this very `lbl` value for the these
  ## vertex IDs.
  if db.top.delta.pAmk.hasKey lbl:
    return ok(db.top.delta.pAmk.getOrVoid lbl)

  for w in db.stack.reversed:
    if w.delta.pAmk.hasKey lbl:
      return ok(w.delta.pAmk.getOrVoid lbl)

  err()

proc layersGetLebalOrVoid*(db: AristoDbRef; lbl: HashLabel): HashSet[VertexID] =
  ## Simplified version of `layersGetVidsOrVoid()`
  db.layersGetLebal(lbl).valueOr: EmptyVidSet

# ------------------------------------------------------------------------------
# Public functions: put variants
# ------------------------------------------------------------------------------

proc layersPutVtx*(db: AristoDbRef; vid: VertexID; vtx: VertexRef) =
  ## Store a (potentally empty) vertex on the top layer
  db.top.delta.sTab[vid] = vtx
  db.top.final.dirty = true # Modified top cache layers

proc layersResVtx*(db: AristoDbRef; vid: VertexID) =
  ## Shortcut for `db.layersPutVtx(vid, VertexRef(nil))`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutVtx(vid, VertexRef(nil))


proc layersPutLabel*(db: AristoDbRef; vid: VertexID; lbl: HashLabel) =
  ## Store a (potentally void) hash label on the top layer

  # Get previous label
  let blb = db.top.delta.kMap.getOrVoid vid

  # Update label on `label->vid` mappiing table
  db.top.delta.kMap[vid] = lbl
  db.top.final.dirty = true # Modified top cache layers

  # Clear previous value on reverse table if it has changed
  if blb.isValid and blb != lbl:
    db.top.delta.pAmk.withValue(blb, value):
      value[].excl vid
    do: # provide empty lookup
      db.top.delta.pAmk[blb] = db.stackGetLebalOrVoid(blb) - @[vid].toHashSet

  # Add updated value on reverse table if non-zero
  if lbl.isValid:
    db.top.delta.pAmk.withValue(lbl, value):
      value[].incl vid
    do: # else if not found: need to merge with value set from lower layer
      db.top.delta.pAmk[lbl] = db.stackGetLebalOrVoid(lbl) + @[vid].toHashSet


proc layersResLabel*(db: AristoDbRef; vid: VertexID) =
  ## Shortcut for `db.layersPutLabel(vid, VOID_HASH_LABEL)`. It is sort of the
  ## equivalent of a delete function.
  db.layersPutLabel(vid, VOID_HASH_LABEL)

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc layersMergeOnto*(src: LayerRef; trg: LayerRef): LayerRef {.discardable.} =
  ## Merges the argument `src` into the argument `trg` and returns `trg`. For
  ## the result layer, the `txUid` value set to `0`.
  trg.final = src.final
  trg.txUid = 0

  for (vid,vtx) in src.delta.sTab.pairs:
    trg.delta.sTab[vid] = vtx

  for (vid,lbl) in src.delta.kMap.pairs:
    trg.delta.kMap[vid] = lbl

  for (lbl,vids) in src.delta.pAmk.pairs:
    trg.delta.pAmk.withValue(lbl, value):
      value[] = value[] + vids
    do:
      trg.delta.pAmk[lbl] = vids

  trg


proc layersCc*(db: AristoDbRef; level = high(int)): LayerRef =
  ## Provide a collapsed copy of layers up to a particular transaction level.
  ## If the `level` argument is too large, the maximum transaction level is
  ## returned. For the result layer, the `txUid` value set to `0`.
  let level = min(level, db.stack.len)

  result = LayerRef(final: db.top.final)       # Pre-merged/final values

  # Merge stack into its bottom layer
  if level <= 0 and db.stack.len == 0:
    result.delta = db.top.delta.dup            # Explicit dup for ref values
  else:
    # now: 0 < level <= db.stack.len
    result.delta = db.stack[0].delta.dup       # Explicit dup for ref values

    # Merge stack: structural vertex table and hash key mapping
    for w in db.stack.reversed:
      w.layersMergeOnto result

    # Merge top layer
    db.top.layersMergeOnto result

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator layersWalkVtx*(
    db: AristoDbRef;
    seen: var HashSet[VertexID];
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Walk over all `(VertexID,VertexRef)` pairs on the cache layers. Note that
  ## entries are unsorted.
  ##
  ## The argument `seen` collects a set of all visited vertex IDs including
  ## the one with a zero vertex which are othewise skipped by the iterator.
  ## The `seen` argument must not be modified while the iterator is active.
  ##
  for (vid,vtx) in db.top.delta.sTab.pairs:
    yield (vid,vtx)
    seen.incl vid

  for w in db.stack.reversed:
    for (vid,vtx) in w.delta.sTab.pairs:
      if vid notin seen:
        yield (vid,vtx)
        seen.incl vid

iterator layersWalkVtx*(
    db: AristoDbRef;
      ): tuple[vid: VertexID, vtx: VertexRef] =
  ## Variant of `layersWalkVtx()`.
  var seen: HashSet[VertexID]
  for (vid,vtx) in db.layersWalkVtx seen:
    yield (vid,vtx)


iterator layersWalkLabel*(
    db: AristoDbRef;
      ): tuple[vid: VertexID, lbl: HashLabel] =
  ## Walk over all `(VertexID,HashLabel)` pairs on the cache layers. Note that
  ## entries are unsorted.
  var seen: HashSet[VertexID]
  for (vid,lbl) in db.top.delta.kMap.pairs:
    yield (vid,lbl)
    seen.incl vid

  for w in db.stack.reversed:
    for (vid,lbl) in w.delta.kMap.pairs:
      if vid notin seen:
        yield (vid,lbl)
        seen.incl vid


iterator layersWalkLebal*(
    db: AristoDbRef;
      ): tuple[lbl: HashLabel, vids: HashSet[VertexID]] =
  ## Walk over `(HashLabel,HashSet[VertexID])` pairs.
  var seen: HashSet[HashLabel]
  for (lbl,vids) in db.top.delta.pAmk.pairs:
    yield (lbl,vids)
    seen.incl lbl

  for w in db.stack.reversed:
    for  (lbl,vids) in w.delta.pAmk.pairs:
      if lbl notin seen:
        yield (lbl,vids)
        seen.incl lbl

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
