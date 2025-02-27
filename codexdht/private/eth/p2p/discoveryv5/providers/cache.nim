# codex-dht - Codex DHT
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import std/sequtils

import pkg/chronicles
import pkg/libp2p
import pkg/questionable

import ../node
import ../lru
import ./common

const
  MaxProvidersEntries* = 1000'u # one thousand records
  MaxProvidersPerEntry* = 200'u  # providers per entry

logScope:
  topics = "discv5 providers cache"

type
  Providers* = LRUCache[PeerId, SignedPeerRecord]
  ItemsCache* = LRUCache[NodeId, Providers]

  ProvidersCache* = object
    disable: bool
    cache*: ItemsCache
    maxProviders*: int

func add*(
  self: var ProvidersCache,
  id: NodeId,
  record: SignedPeerRecord) =
  ## Add providers for an id
  ## to the cache

  if self.disable:
    return

  without var providers =? self.cache.get(id):
    providers = Providers.init(self.maxProviders.int)

  let
    peerId = record.data.peerId

  trace "Adding provider record to cache", id, peerId
  providers.put(peerId, record)
  self.cache.put(id, providers)

proc get*(
  self: var ProvidersCache,
  id: NodeId,
  start = 0,
  stop = MaxProvidersPerEntry.int): seq[SignedPeerRecord] =
  ## Get providers for an id
  ## from the cache

  if self.disable:
    return

  if recs =? self.cache.get(id):
    let
      providers = toSeq(recs)[start..<min(recs.len, stop)]

    trace "Providers already cached", id, len = providers.len
    return providers

func remove*(
  self: var ProvidersCache,
  peerId: PeerId) =
  ## Remove a provider record from an id
  ## from the cache
  ##

  if self.disable:
    return

  for id in self.cache.keys:
    if var providers =? self.cache.get(id):
      trace "Removing provider from cache", id, peerId
      providers.del(peerId)
      self.cache.put(id, providers)

func remove*(
  self: var ProvidersCache,
  id: NodeId,
  peerId: PeerId) =
  ## Remove a provider record from an id
  ## from the cache
  ##

  if self.disable:
    return

  if var providers =? self.cache.get(id):
    trace "Removing record from cache", id
    providers.del(peerId)
    self.cache.put(id, providers)

func drop*(self: var ProvidersCache, id: NodeId) =
  ## Drop all the providers for an entry
  ##

  if self.disable:
    return

  self.cache.del(id)

func init*(
  T: type ProvidersCache,
  size = MaxProvidersEntries,
  maxProviders = MaxProvidersEntries,
  disable = false): T =

  T(
    cache: ItemsCache.init(size.int),
    maxProviders: maxProviders.int,
    disable: disable)
