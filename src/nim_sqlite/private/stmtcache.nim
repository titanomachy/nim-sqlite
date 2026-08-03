## Implements a least-recently-used cache for prepared statements based on
## https://github.com/jackhftang/lrucache.nim.

import std / [lists, tables]
from pkg / sqlite3_abi as abi import nil

type
  Node = object
    key: string
    val: ptr abi.sqlite3_stmt
    leased: bool

  StmtCache* = object 
    capacity: int
    list: DoublyLinkedList[Node]
    table: Table[string, DoublyLinkedNode[Node]]

proc initStmtCache*(capacity: Natural): StmtCache =
  ## Create a new Least-Recently-Used (LRU) cache that store the last `capacity`-accessed items.
  StmtCache(
    capacity: capacity,
    list: initDoublyLinkedList[Node](),
    table: initTable[string, DoublyLinkedNode[Node]](capacity)
  )

proc capacity*(cache: StmtCache): int = 
  ## Get the maximum capacity of cache
  cache.capacity

proc len*(cache: StmtCache): int = 
  ## Return number of keys in cache
  cache.table.len

proc contains*(cache: StmtCache, key: string): bool =
  ## Check whether key in cache. Does *NOT* update recentness.
  cache.table.contains(key)

proc clear*(cache: var StmtCache) =
  ## Finalize and remove all statements owned by the cache.
  for item in cache.list:
    discard abi.sqlite3_finalize(item.val)
  cache.list = initDoublyLinkedList[Node]()
  cache.table.clear()

proc `[]`*(cache: var StmtCache, key: string): ptr abi.sqlite3_stmt =
  ## Read value from `cache` by `key` and update recentness
  ## Raise `KeyError` if `key` is not in `cache`.
  let node = cache.table[key]
  result = node.value.val
  cache.list.remove node
  cache.list.prepend node

proc tryAcquire*(cache: var StmtCache, key: string): ptr abi.sqlite3_stmt =
  ## Tries to lease the cached statement for ``key``. Returns nil when the key
  ## is absent or its statement is already leased or busy.
  let node = cache.table.getOrDefault(key, nil)
  if node.isNil or node.value.leased or abi.sqlite3_stmt_busy(node.value.val) != 0:
    return nil
  node.value.leased = true
  cache.list.remove node
  cache.list.prepend node
  node.value.val

proc release*(cache: var StmtCache, key: string, val: ptr abi.sqlite3_stmt) =
  ## Returns a leased statement to the cache.
  let node = cache.table.getOrDefault(key, nil)
  doAssert not node.isNil and node.value.val == val and node.value.leased,
    "Attempted to release a statement that is not leased from this cache"
  node.value.leased = false

proc tryAdd*(cache: var StmtCache, key: string,
    val: ptr abi.sqlite3_stmt, leased = false): bool =
  ## Tries to transfer ownership of ``val`` to the cache. If the cache is full,
  ## the least-recently-used idle statement is evicted. Leased and busy
  ## statements are never evicted. Returns false, leaving ownership with the
  ## caller, when the key is already cached or every possible eviction candidate
  ## is leased or busy.
  if cache.table.contains(key) or cache.capacity == 0:
    return false

  if cache.table.len >= cache.capacity:
    var candidate = cache.list.tail
    while not candidate.isNil and (candidate.value.leased or
        abi.sqlite3_stmt_busy(candidate.value.val) != 0):
      candidate = candidate.prev
    if candidate.isNil:
      return false
    cache.table.del(candidate.value.key)
    discard abi.sqlite3_finalize(candidate.value.val)
    cache.list.remove candidate

  let node = newDoublyLinkedNode[Node](Node(key: key, val: val, leased: leased))
  cache.table[key] = node
  cache.list.prepend node
  true
