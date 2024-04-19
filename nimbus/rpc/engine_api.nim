# Nimbus
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[typetraits, sequtils, sets],
  json_rpc/rpcserver,
  web3/[conversions, execution_types],
  ../beacon/api_handler,
  ../beacon/beacon_engine,
  ../beacon/web3_eth_conv

{.push raises: [].}

const supportedMethods: HashSet[string] =
  toHashSet([
    "engine_newPayloadV1",
    "engine_newPayloadV2",
    "engine_newPayloadV3",
    "engine_newPayloadV4",
    "engine_getPayloadV1",
    "engine_getPayloadV2",
    "engine_getPayloadV3",
    "engine_getPayloadV4",
    "engine_exchangeTransitionConfigurationV1",
    "engine_forkchoiceUpdatedV1",
    "engine_forkchoiceUpdatedV2",
    "engine_forkchoiceUpdatedV3",
    "engine_getPayloadBodiesByHashV1",
    "engine_getPayloadBodiesByRangeV1",
  ])

# I'm trying to keep the handlers below very thin, and move the
# bodies up to the various procs above. Once we have multiple
# versions, they'll need to be able to share code.
proc setupEngineAPI*(engine: BeaconEngineRef, server: RpcServer) =

  server.rpc("engine_exchangeCapabilities") do(methods: seq[string]) -> seq[string]:
    return methods.filterIt(supportedMethods.contains(it))

  server.rpc("engine_newPayloadV1") do(payload: ExecutionPayloadV1) -> PayloadStatusV1:
    return engine.newPayload(Version.V1, payload.executionPayload)

  server.rpc("engine_newPayloadV2") do(payload: ExecutionPayload) -> PayloadStatusV1:
    return engine.newPayload(Version.V2, payload)

  server.rpc("engine_newPayloadV3") do(payload: ExecutionPayload,
                                       expectedBlobVersionedHashes: Option[seq[Web3Hash]],
                                       parentBeaconBlockRoot: Option[Web3Hash]) -> PayloadStatusV1:
    return engine.newPayload(Version.V3, payload, expectedBlobVersionedHashes, parentBeaconBlockRoot)

  server.rpc("engine_newPayloadV4") do(payload: ExecutionPayload,
                                       expectedBlobVersionedHashes: Option[seq[Web3Hash]],
                                       parentBeaconBlockRoot: Option[Web3Hash]) -> PayloadStatusV1:
    return engine.newPayload(Version.V4, payload, expectedBlobVersionedHashes, parentBeaconBlockRoot)

  server.rpc("engine_getPayloadV1") do(payloadId: PayloadID) -> ExecutionPayloadV1:
    return engine.getPayload(Version.V1, payloadId).executionPayload.V1

  server.rpc("engine_getPayloadV2") do(payloadId: PayloadID) -> GetPayloadV2Response:
    return engine.getPayload(Version.V2, payloadId)

  server.rpc("engine_getPayloadV3") do(payloadId: PayloadID) -> GetPayloadV3Response:
    return engine.getPayloadV3(payloadId)

  server.rpc("engine_getPayloadV4") do(payloadId: PayloadID) -> GetPayloadV4Response:
    return engine.getPayloadV4(payloadId)

  server.rpc("engine_exchangeTransitionConfigurationV1") do(
                       conf: TransitionConfigurationV1) -> TransitionConfigurationV1:
    return engine.exchangeConf(conf)

  server.rpc("engine_forkchoiceUpdatedV1") do(update: ForkchoiceStateV1,
                    attrs: Option[PayloadAttributesV1]) -> ForkchoiceUpdatedResponse:
    return engine.forkchoiceUpdated(Version.V1, update, attrs.payloadAttributes)

  server.rpc("engine_forkchoiceUpdatedV2") do(update: ForkchoiceStateV1,
                    attrs: Option[PayloadAttributes]) -> ForkchoiceUpdatedResponse:
    return engine.forkchoiceUpdated(Version.V2, update, attrs)

  server.rpc("engine_forkchoiceUpdatedV3") do(update: ForkchoiceStateV1,
                    attrs: Option[PayloadAttributes]) -> ForkchoiceUpdatedResponse:
    return engine.forkchoiceUpdated(Version.V3, update, attrs)

  server.rpc("engine_getPayloadBodiesByHashV1") do(hashes: seq[Web3Hash]) ->
                                               seq[Option[ExecutionPayloadBodyV1]]:
    return engine.getPayloadBodiesByHash(hashes)

  server.rpc("engine_getPayloadBodiesByRangeV1") do(
      start: Quantity, count: Quantity) -> seq[Option[ExecutionPayloadBodyV1]]:
    return engine.getPayloadBodiesByRange(start.uint64, count.uint64)
