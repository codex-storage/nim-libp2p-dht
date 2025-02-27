# codex-dht - Codex DHT
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import std/sequtils
import std/strutils
from std/times import now, utc, toTime, toUnix

import pkg/stew/endians2
import pkg/datastore
import pkg/chronos
import pkg/libp2p
import pkg/chronicles
import pkg/stew/results as rs
import pkg/stew/byteutils
import pkg/questionable
import pkg/questionable/results

{.push raises: [].}

import ./maintenance
import ./cache
import ./common
import ../spr

export cache, datastore

logScope:
  topics = "discv5 providers manager"

const
  DefaultProviderTTL* = 24.hours

type
  ProvidersManager* = ref object of RootObj
    store*: Datastore
    cache*: ProvidersCache
    ttl*: Duration
    maxItems*: uint
    maxProviders*: uint
    disableCache*: bool
    expiredLoop*: Future[void]
    orphanedLoop*: Future[void]
    started*: bool
    batchSize*: int
    cleanupInterval*: Duration

proc getProvByKey*(self: ProvidersManager, key: Key): Future[?!SignedPeerRecord] {.async.} =

  without bytes =? (await self.store.get(key)) and bytes.len <= 0:
    trace "No provider in store"
    return failure("No no provider in store")

  return SignedPeerRecord.decode(bytes).mapErr(mapFailure)

proc add*(
  self: ProvidersManager,
  id: NodeId,
  provider: SignedPeerRecord,
  ttl = ZeroDuration): Future[?!void] {.async.} =

  let
    peerId = provider.data.peerId

  trace "Adding provider to persistent store", id, peerId
  without provKey =? makeProviderKey(peerId), err:
    trace "Error creating key from provider record", err = err.msg
    return failure err.msg

  without cidKey =? makeCidKey(id, peerId), err:
    trace "Error creating key from content id", err = err.msg
    return failure err.msg

  let
    now = times.now().utc().toTime().toUnix()
    expires =
      if ttl > ZeroDuration:
        ttl.seconds + now
      else:
        self.ttl.seconds + now
    ttl = endians2.toBytesBE(expires.uint64)

    bytes: seq[byte] =
      if existing =? (await self.getProvByKey(provKey)) and
        existing.data.seqNo >= provider.data.seqNo:
        trace "Provider with same seqNo already exist", seqNo = $provider.data.seqNo
        @[]
      else:
        without bytes =? provider.envelope.encode:
          trace "Enable to encode provider"
          return failure "Unable to encode provider"
        bytes

  if bytes.len > 0:
    trace "Adding or updating provider record", id, peerId
    if err =? (await self.store.put(provKey, bytes)).errorOption:
      trace "Unable to store provider with key", key = provKey, err = err.msg

  trace "Adding or updating id", id, key = cidKey, ttl = expires.seconds
  if err =? (await self.store.put(cidKey, @ttl)).errorOption:
    trace "Unable to store provider with key", key = cidKey, err = err.msg
    return

  self.cache.add(id, provider)
  trace "Provider for id added", cidKey, provKey
  return success()

proc get*(
  self: ProvidersManager,
  id: NodeId,
  start = 0,
  stop = MaxProvidersPerEntry.int): Future[?!seq[SignedPeerRecord]] {.async.} =
  trace "Retrieving providers from persistent store", id

  let
    provs = self.cache.get(id, start = start, stop = stop)

  if provs.len > 0:
    return success provs

  without cidKey =? (CidKey / id.toHex), err:
    return failure err.msg

  trace "Querying providers from persistent store", id, key = cidKey
  var
    providers: seq[SignedPeerRecord]

  block:
    without cidIter =?
      (await self.store.query(Query.init(cidKey, offset = start, limit = stop))), err:
      return failure err.msg

    defer:
      if not isNil(cidIter):
        trace "Cleaning up query iterator"
        discard (await cidIter.dispose())

    var keys: seq[Key]
    for item in cidIter:
      # TODO: =? doesn't support tuples
      if (maybeKey, val) =? (await item) and key =? maybeKey:
        without pairs =? key.fromCidKey() and
          provKey =? makeProviderKey(pairs.peerId), err:
          trace "Error creating key from provider record", err = err.msg
          continue

        trace "Querying provider key", key = provKey
        without data =? (await self.store.get(provKey)):
          trace "Error getting provider", key = provKey
          keys.add(key)
          continue

        without provider =? SignedPeerRecord.decode(data).mapErr(mapFailure), err:
          trace "Unable to decode provider from store", err = err.msg
          keys.add(key)
          continue

        trace "Retrieved provider with key", key = provKey
        providers.add(provider)
        self.cache.add(id, provider)

    trace "Deleting keys without provider from store", len = keys.len
    if keys.len > 0 and err =? (await self.store.delete(keys)).errorOption:
      trace "Error deleting records from persistent store", err = err.msg
      return failure err

    trace "Retrieved providers from persistent store", id = id, len = providers.len
  return success providers

proc contains*(
  self: ProvidersManager,
  id: NodeId,
  peerId: PeerId): Future[bool] {.async.} =
  without key =? makeCidKey(id, peerId), err:
    return false

  return (await self.store.has(key)) |? false

proc contains*(self: ProvidersManager, peerId: PeerId): Future[bool] {.async.} =
  without provKey =? makeProviderKey(peerId), err:
    return false

  return (await self.store.has(provKey)) |? false

proc contains*(self: ProvidersManager, id: NodeId): Future[bool] {.async.} =
  without cidKey =? (CidKey / $id), err:
    return false

  let
    q = Query.init(cidKey, limit = 1)

  block:
    without iter =? (await self.store.query(q)), err:
      trace "Unable to obtain record for key", key = cidKey
      return false

    defer:
      if not isNil(iter):
        trace "Cleaning up query iterator"
        discard (await iter.dispose())

    for item in iter:
      if (key, _) =? (await item) and key.isSome:
        return true

  return false

proc remove*(self: ProvidersManager, id: NodeId): Future[?!void] {.async.} =

  self.cache.drop(id)
  without cidKey =? (CidKey / $id), err:
    return failure(err.msg)

  let
    q = Query.init(cidKey)

  block:
    without iter =? (await self.store.query(q)), err:
      trace "Unable to obtain record for key", key = cidKey
      return failure err

    defer:
      if not isNil(iter):
        trace "Cleaning up query iterator"
        discard (await iter.dispose())

    var
      keys: seq[Key]

    for item in iter:
      if (maybeKey, _) =? (await item) and key =? maybeKey:

        keys.add(key)
        without pairs =? key.fromCidKey, err:
          trace "Unable to parse peer id from key", key
          return failure err

        self.cache.remove(id, pairs.peerId)
        trace "Deleted record from store", key

    if keys.len > 0 and err =? (await self.store.delete(keys)).errorOption:
      trace "Error deleting record from persistent store", err = err.msg
      return failure err

  return success()

proc remove*(
  self: ProvidersManager,
  peerId: PeerId,
  entries = false): Future[?!void] {.async.} =

  if entries:
    without cidKey =? (CidKey / "*" / $peerId), err:
      return failure err

    let
      q = Query.init(cidKey)

    block:
      without iter =? (await self.store.query(q)), err:
        trace "Unable to obtain record for key", key = cidKey
        return failure err

      defer:
        if not isNil(iter):
          trace "Cleaning up query iterator"
          discard (await iter.dispose())

      var
        keys: seq[Key]

      for item in iter:
        if (maybeKey, _) =? (await item) and key =? maybeKey:
          keys.add(key)

          let
            parts = key.id.split(datastore.Separator)

      if keys.len > 0 and err =? (await self.store.delete(keys)).errorOption:
        trace "Error deleting record from persistent store", err = err.msg
        return failure err

      trace "Deleted records from store"

  without provKey =? peerId.makeProviderKey, err:
    return failure err

  trace "Removing provider from cache", peerId
  self.cache.remove(peerId)

  trace "Removing provider record", key = provKey
  return (await self.store.delete(provKey))

proc remove*(
  self: ProvidersManager,
  id: NodeId,
  peerId: PeerId): Future[?!void] {.async.} =

  self.cache.remove(id, peerId)
  without cidKey =? makeCidKey(id, peerId), err:
    trace "Error creating key from content id", err = err.msg
    return failure err.msg

  return (await self.store.delete(cidKey))

proc cleanupExpiredLoop(self: ProvidersManager) {.async.} =
  try:
    while self.started:
      await self.store.cleanupExpired(self.batchSize)
      await sleepAsync(self.cleanupInterval)
  except CancelledError as exc:
    trace "Cancelled expired cleanup job", err = exc.msg
  except CatchableError as exc:
    trace "Exception in expired cleanup job", err = exc.msg
    raiseAssert "Exception in expired cleanup job"

proc cleanupOrphanedLoop(self: ProvidersManager) {.async.} =
  try:
    while self.started:
      await self.store.cleanupOrphaned(self.batchSize)
      await sleepAsync(self.cleanupInterval)
  except CancelledError as exc:
    trace "Cancelled orphaned cleanup job", err = exc.msg
  except CatchableError as exc:
    trace "Exception in orphaned cleanup job", err = exc.msg
    raiseAssert "Exception in orphaned cleanup job"

proc start*(self: ProvidersManager) {.async.} =
  self.started = true
  self.expiredLoop = self.cleanupExpiredLoop
  self.orphanedLoop = self.cleanupOrphanedLoop

proc stop*(self: ProvidersManager) {.async.} =
  await self.expiredLoop.cancelAndWait()
  await self.orphanedLoop.cancelAndWait()
  self.started = false

func new*(
  T: type ProvidersManager,
  store: Datastore,
  disableCache = false,
  ttl = DefaultProviderTTL,
  maxItems = MaxProvidersEntries,
  maxProviders = MaxProvidersPerEntry,
  batchSize = ExpiredCleanupBatch,
  cleanupInterval = CleanupInterval): T =

  T(
    store: store,
    ttl: ttl,
    maxItems: maxItems,
    maxProviders: maxProviders,
    disableCache: disableCache,
    batchSize: batchSize,
    cleanupInterval: cleanupInterval,
    cache: ProvidersCache.init(
      size = maxItems,
      maxProviders = maxProviders,
      disable = disableCache))
