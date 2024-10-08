# nimbus-eth1
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Aristo DB -- Delta filter management
## ====================================
##

import
  std/[strutils, tables],
  chronicles,
  eth/common,
  results,
  ./aristo_delta/[delta_merge, delta_reverse],
  ./aristo_desc/desc_backend,
  "."/[aristo_desc, aristo_get, aristo_layers, aristo_utils]

logScope:
  topics = "aristo-delta"

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc toStr(rvid: RootedVertexID): string =
  "$" & rvid.root.uint64.toHex & ":" & rvid.vid.uint64.toHex

proc delSubTree(db: AristoDbRef; writer: PutHdlRef; rvid: RootedVertexID) =
  ## Collect subtrees marked for deletion
  let (vtx,_) = db.getVtxRc(rvid).valueOr:
    notice "Descending for deletion stopped", rvid=(rvid.toStr), error
    return
  for vid in vtx.subVids:
    db.delSubTree(writer, (rvid.root, vid))
  db.backend.putVtxFn(writer, rvid, VertexRef(nil))
  db.backend.putKeyFn(writer, rvid, VOID_HASH_KEY)
  # Make sure the `rvid` is not mentioned here, anymore for further update.
  db.balancer.sTab.del rvid
  db.balancer.kMap.del rvid

# ------------------------------------------------------------------------------
# Public functions, save to backend
# ------------------------------------------------------------------------------

proc deltaPersistentOk*(db: AristoDbRef): bool =
  ## Check whether the read-only filter can be merged into the backend
  not db.backend.isNil and db.isCentre


proc deltaPersistent*(
    db: AristoDbRef;                   # Database
    nxtFid = 0u64;                     # Next filter ID (if any)
    reCentreOk = false;
      ): Result[void,AristoError] =
  ## Resolve (i.e. move) the balancer into the physical backend database.
  ##
  ## This needs write permission on the backend DB for the descriptor argument
  ## `db` (see the function `aristo_desc.isCentre()`.) If the argument flag
  ## `reCentreOk` is passed `true`, write permission will be temporarily
  ## acquired when needed.
  ##
  ## When merging the current backend filter, its reverse will be is stored
  ## on other non-centre descriptors so there is no visible database change
  ## for these.
  ##
  let be = db.backend
  if be.isNil:
    return err(FilBackendMissing)

  # Blind or missing filter
  if db.balancer.isNil:
    return ok()

  # Make sure that the argument `db` is at the centre so the backend is in
  # read-write mode for this peer.
  let parent = db.getCentre
  if db != parent:
    if not reCentreOk:
      return err(FilBackendRoMode)
    ? db.reCentre()
  # Always re-centre to `parent` (in case `reCentreOk` was set)
  defer: discard parent.reCentre()

  # Update forked balancers here do that errors are detected early (if any.)
  if 0 < db.nForked:
    let rev = db.revFilter(db.balancer).valueOr:
      return err(error[1])
    if not rev.isEmpty: # Can an empty `rev` happen at all?
      var unsharedRevOk = true
      for w in db.forked:
        if not w.db.balancer.isValid:
          unsharedRevOk = false
        # The `rev` filter can be modified if one can make sure that it is
        # not shared (i.e. only previously merged into the w.db.balancer.)
        # Note that it is trivially true for a single fork.
        let modLowerOk = w.isLast and unsharedRevOk
        w.db.balancer = deltaMerge(
          w.db.balancer, modUpperOk=false, rev, modLowerOk=modLowerOk)

  let lSst = SavedState(
    key:  EMPTY_ROOT_HASH,                       # placeholder for more
    serial: nxtFid)

  # Store structural single trie entries
  let writeBatch = ? be.putBegFn()
  # This one must come first in order to avoid duplicate `sTree[]` or
  # `kMap[]` instructions, in the worst case overwiting previously deleted
  # entries.
  for rvid in db.balancer.delTree:
    db.delSubTree(writeBatch, rvid)
  # Now the standard `sTree[]` and `kMap[]` instructions.
  for rvid, vtx in db.balancer.sTab:
    be.putVtxFn(writeBatch, rvid, vtx)
  for rvid, key in db.balancer.kMap:
    be.putKeyFn(writeBatch, rvid, key)
  be.putTuvFn(writeBatch, db.balancer.vTop)
  be.putLstFn(writeBatch, lSst)
  ? be.putEndFn writeBatch                       # Finalise write batch

  # Copy back updated payloads
  for accPath, vtx in db.balancer.accLeaves:
    let accKey = accPath.to(AccountKey)
    if not db.accLeaves.lruUpdate(accKey, vtx):
      discard db.accLeaves.lruAppend(accKey, vtx, ACC_LRU_SIZE)

  for mixPath, vtx in db.balancer.stoLeaves:
    let mixKey = mixPath.to(AccountKey)
    if not db.stoLeaves.lruUpdate(mixKey, vtx):
      discard db.stoLeaves.lruAppend(mixKey, vtx, ACC_LRU_SIZE)

  # Done with balancer, all saved to backend
  db.balancer = LayerRef(nil)

  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
