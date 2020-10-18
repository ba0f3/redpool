import asyncdispatch, times, net
import redis

type
  RedisConn = ref object
    conn: AsyncRedis
    taken: float

  RedisPool* = ref object
    conns: seq[RedisConn]
    host: string
    port: Port
    db: int
    timeout: float
    maxConns: int

proc newRedisConn(pool: RedisPool; taken=false): Future[RedisConn] {.async.} =
  result = RedisConn(
    conn: await openAsync(pool.host, pool.port),
    taken: if taken: epochTime() else: 0
  )

proc newRedisPool*(size: int; maxConns=10; timeout=10.0;
                   host="localhost"; port=6379; db=0): Future[RedisPool] {.async.} =
  result = RedisPool(
    maxConns: maxConns,
    host: host,
    port: Port(port),
    db: db,
    timeout: timeout
  )

  for n in 0 ..< size:
    var conn = await newRedisConn(result)
    discard await conn.conn.select(db)
    result.conns.add conn

proc acquire*(pool: RedisPool): Future[AsyncRedis] {.async.} =
  let now = epochTime()
  for rconn in pool.conns:
    if now - rconn.taken > pool.timeout:
      rconn.taken = now
      return rconn.conn

  let newConn = await newRedisConn(pool, taken=true)
  discard await newConn.conn.select(pool.db)
  pool.conns.add newConn
  return newConn.conn

proc release*(pool: RedisPool; conn: AsyncRedis) =
  for i, rconn in pool.conns:
    if rconn.conn == conn:
      if pool.conns.len > pool.maxConns:
        pool.conns.del(i)
      else:
        rconn.taken = 0
      break

template withAcquire*(pool: RedisPool; conn, body: untyped) =
  let `conn` {.inject.} = waitFor pool.acquire()
  try:
    body
  finally:
    pool.release(`conn`)

when isMainModule:
  proc main {.async.} =
    let pool = await newRedisPool(1)
    let conn = await pool.acquire()
    echo await conn.ping()
    pool.release(conn)

    pool.withAcquire(conn2):
      echo await conn2.ping()

  waitFor main()
