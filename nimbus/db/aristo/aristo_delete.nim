# nimbus-eth1
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Patricia Trie delete funcionality
## ==============================================
##
## Deleate by `Hike` type chain of vertices.

{.push raises: [].}

import
  std/[sets, tables],
  chronicles,
  eth/[common, trie/nibbles],
  results,
  "."/[aristo_desc, aristo_get, aristo_hike, aristo_layers, aristo_path,
       aristo_vid]

logScope:
  topics = "aristo-delete"

# ------------------------------------------------------------------------------
# Private heplers
# ------------------------------------------------------------------------------

func toVae(err: AristoError): (VertexID,AristoError) =
  ## Map single error to error pair with dummy vertex
  (VertexID(0),err)

func toVae(err: (Hike,AristoError)): (VertexID,AristoError) =
  if 0 < err[0].legs.len:
    (err[0].legs[^1].wp.vid, err[1])
  else:
    (VertexID(0), err[1])

proc branchStillNeeded(vtx: VertexRef): Result[int,void] =
  ## Returns the nibble if there is only one reference left.
  var nibble = -1
  for n in 0 .. 15:
    if vtx.bVid[n].isValid:
      if 0 <= nibble:
        return ok(-1)
      nibble = n
  if 0 <= nibble:
    return ok(nibble)
  # Oops, degenerated branch node
  err()

# -----------

proc nullifyKey(
    db: AristoDbRef;                   # Database, top layer
    vid: VertexID;                     # Vertex IDs to clear
      ) =
  # Register for void hash (to be recompiled)
  db.layersResLabel vid

proc disposeOfVtx(
    db: AristoDbRef;                   # Database, top layer
    vid: VertexID;                     # Vertex IDs to clear
      ) =
  # Remove entry
  db.layersResVtx vid
  db.layersResLabel vid
  db.vidDispose vid                    # Recycle ID

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc collapseBranch(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    nibble: byte;                      # Applicable link for `Branch` vertex
     ): Result[void,(VertexID,AristoError)] =
  ## Convert/merge vertices:
  ## ::
  ##   current            | becomes             | condition
  ##                      |                     |
  ##   ^3     ^2          |  ^3     ^2          |
  ##   -------------------+---------------------+------------------
  ##   Branch <br> Branch | Branch <ext> Branch | 2 < legs.len  (1)
  ##   Ext    <br> Branch | <ext>        Branch | 2 < legs.len  (2)
  ##          <br> Branch |        <ext> Branch | legs.len == 2 (3)
  ##
  ## Depending on whether the parent `par` is an extension, merge `br` into
  ## `par`. Otherwise replace `br` by an extension.
  ##
  let br = hike.legs[^2].wp

  var xt = VidVtxPair(                                   # Rewrite `br`
    vid: br.vid,
    vtx: VertexRef(
      vType: Extension,
      ePfx:  @[nibble].initNibbleRange.slice(1),
      eVid:  br.vtx.bVid[nibble]))

  if 2 < hike.legs.len:                                  # (1) or (2)
    let par = hike.legs[^3].wp
    case par.vtx.vType:
    of Branch:                                           # (1)
      # Replace `br` (use `xt` as-is)
      discard

    of Extension:                                        # (2)
      # Merge `br` into ^3 (update `xt`)
      db.disposeOfVtx xt.vid
      xt.vid = par.vid
      xt.vtx.ePfx = par.vtx.ePfx & xt.vtx.ePfx

    of Leaf:
      return err((par.vid,DelLeafUnexpected))

  else:                                                  # (3)
    # Replace `br` (use `xt` as-is)
    discard

  db.layersPutVtx(xt.vid, xt.vtx)
  ok()


proc collapseExt(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    nibble: byte;                      # Link for `Branch` vertex `^2`
    vtx: VertexRef;                    # Follow up extension vertex (nibble)
     ): Result[void,(VertexID,AristoError)] =
  ## Convert/merge vertices:
  ## ::
  ##   ^3       ^2   `vtx` |   ^3      ^2    |
  ##   --------------------+-----------------------+------------------
  ##   Branch  <br>   Ext  |  Branch  <ext>  | 2 < legs.len  (1)
  ##   Ext     <br>   Ext  |  <ext>          | 2 < legs.len  (2)
  ##           <br>   Ext  |          <ext>  | legs.len == 2 (3)
  ##
  ## Merge `vtx` into `br` and unlink `vtx`.
  ##
  let br = hike.legs[^2].wp

  var xt = VidVtxPair(                                   # Merge `vtx` into `br`
    vid: br.vid,
    vtx: VertexRef(
      vType: Extension,
      ePfx:  @[nibble].initNibbleRange.slice(1) & vtx.ePfx,
      eVid:  vtx.eVid))
  db.disposeOfVtx br.vtx.bVid[nibble]                    # `vtx` is obsolete now

  if 2 < hike.legs.len:                                  # (1) or (2)
    let par = hike.legs[^3].wp
    case par.vtx.vType:
    of Branch:                                           # (1)
      # Replace `br` by `^2 & vtx` (use `xt` as-is)
      discard

    of Extension:                                        # (2)
      # Replace ^3 by `^3 & ^2 & vtx` (update `xt`)
      db.disposeOfVtx xt.vid
      xt.vid = par.vid
      xt.vtx.ePfx = par.vtx.ePfx & xt.vtx.ePfx

    of Leaf:
      return err((par.vid,DelLeafUnexpected))

  else:                                                  # (3)
    # Replace ^2 by `^2 & vtx` (use `xt` as-is)
    discard

  db.layersPutVtx(xt.vid, xt.vtx)
  ok()


proc collapseLeaf(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    nibble: byte;                      # Link for `Branch` vertex `^2`
    vtx: VertexRef;                    # Follow up leaf vertex (from nibble)
     ): Result[void,(VertexID,AristoError)] =
  ## Convert/merge vertices:
  ## ::
  ##   current                  | becomes                    | condition
  ##                            |                            |
  ##    ^4     ^3     ^2  `vtx` | ^4      ^3     ^2          |
  ##   -------------------------+----------------------------+------------------
  ##   ..     Branch <br>  Leaf | ..     Branch       <Leaf> | 2 < legs.len  (1)
  ##   Branch Ext    <br>  Leaf | Branch              <Leaf> | 3 < legs.len  (2)
  ##          Ext    <br>  Leaf |              <Leaf>        | legs.len == 3 (3)
  ##                 <br>  Leaf |              <Leaf>        | legs.len == 2 (4)
  ##
  ## Merge `<br>` and `Leaf` replacing one and removing the other.
  ##
  let br = hike.legs[^2].wp

  var lf = VidVtxPair(                                   # Merge `br` into `vtx`
    vid: br.vtx.bVid[nibble],
    vtx: VertexRef(
      vType: Leaf,
      lPfx:  @[nibble].initNibbleRange.slice(1) & vtx.lPfx,
      lData: vtx.lData))
  db.nullifyKey lf.vid                                   # `vtx` was modified

  if 2 < hike.legs.len:                                  # (1), (2), or (3)
    db.disposeOfVtx br.vid                               # `br` is obsolete now
    # Merge `br` into the leaf `vtx` and unlink `br`.
    let par = hike.legs[^3].wp.dup                       # Writable vertex
    case par.vtx.vType:
    of Branch:                                           # (1)
      # Replace `vtx` by `^2 & vtx` (use `lf` as-is)
      par.vtx.bVid[hike.legs[^3].nibble] = lf.vid
      db.layersPutVtx(par.vid, par.vtx)
      db.layersPutVtx(lf.vid, lf.vtx)
      # Make sure that there is a cache enty in case the leaf was pulled from
      # the backend.!
      let
        lfPath = hike.legsTo(hike.legs.len - 2, NibblesSeq) & lf.vtx.lPfx
        tag = lfPath.pathToTag.valueOr:
          return err((lf.vid,error))
      db.top.final.lTab[LeafTie(root: hike.root, path: tag)] = lf.vid
      return ok()

    of Extension:                                        # (2) or (3)
      # Merge `^3` into `lf` but keep the leaf vertex ID unchanged. This
      # avoids some `lTab[]` registry update.
      lf.vtx.lPfx = par.vtx.ePfx & lf.vtx.lPfx

      if 3 < hike.legs.len:                              # (2)
        # Grandparent exists
        let gpr = hike.legs[^4].wp.dup                   # Writable vertex
        if gpr.vtx.vType != Branch:
          return err((gpr.vid,DelBranchExpexted))
        db.disposeOfVtx par.vid                          # `par` is obsolete now
        gpr.vtx.bVid[hike.legs[^4].nibble] = lf.vid
        db.layersPutVtx(gpr.vid, gpr.vtx)
        db.layersPutVtx(lf.vid, lf.vtx)
        # Make sure that there is a cache enty in case the leaf was pulled from
        # the backend.!
        let
          lfPath = hike.legsTo(hike.legs.len - 3, NibblesSeq) & lf.vtx.lPfx
          tag = lfPath.pathToTag.valueOr:
            return err((lf.vid,error))
        db.top.final.lTab[LeafTie(root: hike.root, path: tag)] = lf.vid
        return ok()

      # No grandparent, so ^3 is root vertex             # (3)
      db.layersPutVtx(par.vid, lf.vtx)
      # Continue below

    of Leaf:
      return err((par.vid,DelLeafUnexpected))

  else:                                                  # (4)
    # Replace ^2 by `^2 & vtx` (use `lf` as-is)          # `br` is root vertex
    db.nullifyKey br.vid                                 # root was changed
    db.layersPutVtx(br.vid, lf.vtx)
    # Continue below

  # Common part for setting up `lf` as root vertex       # Rest of (3) or (4)
  let rc = lf.vtx.lPfx.pathToTag
  if rc.isErr:
    return err((br.vid,rc.error))
  #
  # No need to update the cache unless `lf` is present there. The leaf path
  # as well as the value associated with the leaf path has not been changed.
  let lfTie = LeafTie(root: hike.root, path: rc.value)
  if db.top.final.lTab.hasKey lfTie:
    db.top.final.lTab[lfTie] = lf.vid

  # Clean up stale leaf vertex which has moved to root position
  db.disposeOfVtx lf.vid

  # If some `Leaf` vertex was installed as root, there must be a an extra
  # `LeafTie` lookup entry.
  let rootVtx = db.getVtx hike.root
  if rootVtx.isValid and
     rootVtx != hike.legs[0].wp.vtx and
     rootVtx.vType == Leaf:
    let tag = rootVtx.lPfx.pathToTag.valueOr:
      return err((hike.root,error))
    db.top.final.lTab[LeafTie(root: hike.root, path: tag)] = hike.root

  ok()

# -------------------------

proc deleteImpl(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded path
    lty: LeafTie;                      # `Patricia Trie` path root-to-leaf
      ): Result[void,(VertexID,AristoError)] =
  ## Implementation of *delete* functionality.

  # Remove leaf entry on the top
  let lf =  hike.legs[^1].wp
  if lf.vtx.vType != Leaf:
    return err((lf.vid,DelLeafExpexted))
  if lf.vid in db.pPrf:
    return err((lf.vid, DelLeafLocked))

  # Will be needed at the end. Just detect an error early enouhh
  let leafVidBe = block:
    let rc = db.getVtxBE lf.vid
    if rc.isErr:
      if rc.error != GetVtxNotFound:
        return err((lf.vid, rc.error))
      VertexRef(nil)
    else:
      rc.value

  db.disposeOfVtx lf.vid

  if 1 < hike.legs.len:
    # Get current `Branch` vertex `br`
    let br = block:
      var wp = hike.legs[^2].wp
      wp.vtx = wp.vtx.dup # make sure that layers are not impliciteley modified
      wp
    if br.vtx.vType != Branch:
      return err((br.vid,DelBranchExpexted))

    # Unlink child vertex from structural table
    br.vtx.bVid[hike.legs[^2].nibble] = VertexID(0)
    db.layersPutVtx(br.vid, br.vtx)

    # Clear all keys up to the root key
    for n in 0 .. hike.legs.len - 2:
      let vid = hike.legs[n].wp.vid
      if vid in db.top.final.pPrf:
        return err((vid, DelBranchLocked))
      db.nullifyKey vid

    let nibble = block:
      let rc = br.vtx.branchStillNeeded()
      if rc.isErr:
        return err((br.vid,DelBranchWithoutRefs))
      rc.value

    # Convert to `Extension` or `Leaf` vertex
    if 0 <= nibble:
      # Get child vertex (there must be one after a `Branch` node)
      let nxt = block:
        let vid = br.vtx.bVid[nibble]
        VidVtxPair(vid: vid, vtx: db.getVtx vid)
      if not nxt.vtx.isValid:
        return err((nxt.vid, DelVidStaleVtx))

      # Collapse `Branch` vertex `br` depending on `nxt` vertex type
      case nxt.vtx.vType:
      of Branch:
        ? db.collapseBranch(hike, nibble.byte)
      of Extension:
        ? db.collapseExt(hike, nibble.byte, nxt.vtx)
      of Leaf:
        ? db.collapseLeaf(hike, nibble.byte, nxt.vtx)

  # Delete leaf entry
  if leafVidBe.isValid:
    # To be recorded on change history
    db.top.final.lTab[lty] = VertexID(0)
  else:
    # No need to keep it any longer in cache
    db.top.final.lTab.del lty

  ok()

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc delete*(
    db: AristoDbRef;                   # Database, top layer
    hike: Hike;                        # Fully expanded chain of vertices
      ): Result[void,(VertexID,AristoError)] =
  ## Delete argument `hike` chain of vertices from the database
  ##
  # Need path in order to remove it from `lTab[]`
  let lty = LeafTie(
    root: hike.root,
    path: ? hike.to(NibblesSeq).pathToTag().mapErr toVae)
  db.deleteImpl(hike, lty)

proc delete*(
    db: AristoDbRef;                   # Database, top layer
    lty: LeafTie;                      # `Patricia Trie` path root-to-leaf
      ): Result[void,(VertexID,AristoError)] =
  ## Variant of `delete()`
  ##
  db.deleteImpl(? lty.hikeUp(db).mapErr toVae, lty)

proc delete*(
    db: AristoDbRef;
    root: VertexID;
    path: openArray[byte];
     ): Result[void,(VertexID,AristoError)] =
  ## Variant of `delete()`
  ##
  db.delete(? path.initNibbleRange.hikeUp(root, db).mapErr toVae)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
