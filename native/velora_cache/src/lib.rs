//! # velora_cache - bounded in-memory cache NIF for velora
//!
//! A thin rustler NIF around the [`fulgurance`] cache crate. Keys and values are
//! opaque binaries (`Vec<u8>`), so the same cache serves tile PNGs and small
//! metadata blobs alike.
//!
//! ## Why an actor thread
//!
//! `fulgurance::FulgranceCache` is `!Send + !Sync` (it holds a
//! `Box<dyn Fn(&K) -> Option<V>>` prefetch hook). It therefore cannot live in a
//! `ResourceArc<Mutex<..>>`, which requires `Send`. Instead each cache is owned
//! by a dedicated OS thread; the rustler resource holds only a `Sender<Cmd>`
//! (which *is* `Send + Sync`). NIF calls push a command carrying a one-shot
//! reply channel and block on the reply. Access is naturally serialized and the
//! cache value never crosses a thread boundary -- it is *built inside* the actor
//! thread, so `!Send` is never violated.

use rustler::{Atom, Binary, Encoder, Env, OwnedBinary, ResourceArc, Term};
use std::sync::mpsc::{channel, Sender};
use std::thread;

use fulgurance::policies::{
    ArcCache, ClockCache, FifoCache, LfuCache, LruCache, SlruCache, TwoQCache,
};
use fulgurance::prefetch::NoPrefetch;
use fulgurance::{CachePolicy, FulgranceCache};

mod atoms {
    rustler::atoms! {
        ok,
        miss,
    }
}

/// A command sent from a NIF call to the cache actor thread. Every variant
/// carries a one-shot reply channel so the caller can block until the operation
/// has actually run on the actor thread (serializing access, guaranteeing
/// ordering).
enum Cmd {
    Get {
        key: Vec<u8>,
        reply: Sender<Option<Vec<u8>>>,
    },
    Insert {
        key: Vec<u8>,
        val: Vec<u8>,
        reply: Sender<()>,
    },
    Remove {
        key: Vec<u8>,
        reply: Sender<()>,
    },
    Clear {
        reply: Sender<()>,
    },
    /// Reply is `(hits, misses, len, capacity)`.
    Stats {
        reply: Sender<(u64, u64, u64, u64)>,
    },
}

/// Object-safe view over a `FulgranceCache` for any eviction policy. This lets
/// the actor own a single boxed cache whose policy was chosen at runtime.
///
/// Deliberately **not** `Send`: `FulgranceCache` is `!Send`, and the box is
/// constructed and used entirely within the actor thread.
trait AnyCache {
    fn get(&mut self, key: &Vec<u8>) -> Option<Vec<u8>>;
    fn insert(&mut self, key: Vec<u8>, val: Vec<u8>);
    fn remove(&mut self, key: &Vec<u8>) -> Option<Vec<u8>>;
    fn clear(&mut self);
    /// `(hits, misses, len, capacity)`
    fn stats(&self) -> (u64, u64, u64, u64);
}

impl<C> AnyCache for FulgranceCache<Vec<u8>, Vec<u8>, C, NoPrefetch>
where
    C: CachePolicy<Vec<u8>, Vec<u8>>,
{
    fn get(&mut self, key: &Vec<u8>) -> Option<Vec<u8>> {
        FulgranceCache::get(self, key)
    }
    fn insert(&mut self, key: Vec<u8>, val: Vec<u8>) {
        FulgranceCache::insert(self, key, val)
    }
    fn remove(&mut self, key: &Vec<u8>) -> Option<Vec<u8>> {
        FulgranceCache::remove(self, key)
    }
    fn clear(&mut self) {
        FulgranceCache::clear(self)
    }
    fn stats(&self) -> (u64, u64, u64, u64) {
        let s = FulgranceCache::stats(self);
        (
            s.hits,
            s.misses,
            FulgranceCache::len(self) as u64,
            FulgranceCache::capacity(self) as u64,
        )
    }
}

/// Build the concrete cache for a policy name. Runs on the actor thread only.
/// Unknown policies fall back to 2Q, which is scan-resistant (a pan across a
/// whole scene will not evict the hot centre).
fn build_cache(policy: &[u8], capacity: usize) -> Box<dyn AnyCache> {
    match policy {
        b"lru" => Box::new(FulgranceCache::new(LruCache::new(capacity), NoPrefetch)),
        b"twoq" => Box::new(FulgranceCache::new(TwoQCache::new(capacity), NoPrefetch)),
        b"arc" => Box::new(FulgranceCache::new(ArcCache::new(capacity), NoPrefetch)),
        b"slru" => Box::new(FulgranceCache::new(SlruCache::new(capacity), NoPrefetch)),
        b"clock" => Box::new(FulgranceCache::new(ClockCache::new(capacity), NoPrefetch)),
        b"lfu" => Box::new(FulgranceCache::new(LfuCache::new(capacity), NoPrefetch)),
        b"fifo" => Box::new(FulgranceCache::new(FifoCache::new(capacity), NoPrefetch)),
        // Default: scan-resistant 2Q.
        _ => Box::new(FulgranceCache::new(TwoQCache::new(capacity), NoPrefetch)),
    }
}

/// The resource handed to Erlang: just the channel to the actor. Cloneable,
/// `Send + Sync`. When the last `ResourceArc` is dropped the `Sender` drops,
/// the actor's `recv()` returns `Err`, and the thread exits cleanly.
struct CacheHandle {
    tx: Sender<Cmd>,
}

#[rustler::resource_impl]
impl rustler::Resource for CacheHandle {}

/// Spawn the actor thread and return a handle to it.
fn spawn_cache(policy: Vec<u8>, capacity: usize) -> CacheHandle {
    let (tx, rx) = channel::<Cmd>();
    thread::spawn(move || {
        // The `!Send` cache is created and lives entirely on this thread.
        let mut cache = build_cache(&policy, capacity);
        while let Ok(cmd) = rx.recv() {
            match cmd {
                Cmd::Get { key, reply } => {
                    let _ = reply.send(cache.get(&key));
                }
                Cmd::Insert { key, val, reply } => {
                    cache.insert(key, val);
                    let _ = reply.send(());
                }
                Cmd::Remove { key, reply } => {
                    let _ = cache.remove(&key);
                    let _ = reply.send(());
                }
                Cmd::Clear { reply } => {
                    cache.clear();
                    let _ = reply.send(());
                }
                Cmd::Stats { reply } => {
                    let _ = reply.send(cache.stats());
                }
            }
        }
    });
    CacheHandle { tx }
}

// ---------------------------------------------------------------------------
// NIFs
// ---------------------------------------------------------------------------

/// `new(Capacity, PolicyBin) -> resource`. `PolicyBin` is an atom name encoded
/// as a binary on the Erlang side (e.g. `<<"lru">>`).
#[rustler::nif(name = "nif_new")]
fn new(capacity: u64, policy: Binary) -> ResourceArc<CacheHandle> {
    let cap = capacity.max(1) as usize;
    let handle = spawn_cache(policy.as_slice().to_vec(), cap);
    ResourceArc::new(handle)
}

/// `get(Res, Key) -> {ok, Bin} | miss`.
#[rustler::nif(name = "nif_get")]
fn get<'a>(env: Env<'a>, res: ResourceArc<CacheHandle>, key: Binary) -> Term<'a> {
    let (rtx, rrx) = channel();
    if res
        .tx
        .send(Cmd::Get {
            key: key.as_slice().to_vec(),
            reply: rtx,
        })
        .is_err()
    {
        return atoms::miss().encode(env);
    }
    match rrx.recv() {
        Ok(Some(bytes)) => {
            let mut bin = OwnedBinary::new(bytes.len()).expect("alloc binary");
            bin.as_mut_slice().copy_from_slice(&bytes);
            (atoms::ok(), bin.release(env)).encode(env)
        }
        _ => atoms::miss().encode(env),
    }
}

/// `put(Res, Key, Val) -> ok`.
#[rustler::nif(name = "nif_put")]
fn put(res: ResourceArc<CacheHandle>, key: Binary, val: Binary) -> Atom {
    let (rtx, rrx) = channel();
    let _ = res.tx.send(Cmd::Insert {
        key: key.as_slice().to_vec(),
        val: val.as_slice().to_vec(),
        reply: rtx,
    });
    let _ = rrx.recv();
    atoms::ok()
}

/// `delete(Res, Key) -> ok`.
#[rustler::nif(name = "nif_delete")]
fn delete(res: ResourceArc<CacheHandle>, key: Binary) -> Atom {
    let (rtx, rrx) = channel();
    let _ = res.tx.send(Cmd::Remove {
        key: key.as_slice().to_vec(),
        reply: rtx,
    });
    let _ = rrx.recv();
    atoms::ok()
}

/// `clear(Res) -> ok`.
#[rustler::nif(name = "nif_clear")]
fn clear(res: ResourceArc<CacheHandle>) -> Atom {
    let (rtx, rrx) = channel();
    let _ = res.tx.send(Cmd::Clear { reply: rtx });
    let _ = rrx.recv();
    atoms::ok()
}

/// `stats(Res) -> {Hits, Misses, Len, Capacity}`. The Erlang wrapper turns this
/// into a map.
#[rustler::nif(name = "nif_stats")]
fn stats(res: ResourceArc<CacheHandle>) -> (u64, u64, u64, u64) {
    let (rtx, rrx) = channel();
    if res.tx.send(Cmd::Stats { reply: rtx }).is_err() {
        return (0, 0, 0, 0);
    }
    rrx.recv().unwrap_or((0, 0, 0, 0))
}

rustler::init!("velora_cache");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn lru(cap: usize) -> Box<dyn AnyCache> {
        build_cache(b"lru", cap)
    }

    #[test]
    fn put_get_roundtrip() {
        let mut c = lru(4);
        c.insert(b"k".to_vec(), b"v".to_vec());
        assert_eq!(c.get(&b"k".to_vec()), Some(b"v".to_vec()));
    }

    #[test]
    fn get_miss() {
        let mut c = lru(4);
        assert_eq!(c.get(&b"absent".to_vec()), None);
    }

    #[test]
    fn capacity_eviction_lru() {
        let mut c = lru(2);
        c.insert(b"a".to_vec(), b"1".to_vec());
        c.insert(b"b".to_vec(), b"2".to_vec());
        c.insert(b"c".to_vec(), b"3".to_vec()); // evicts LRU == "a"
        assert_eq!(c.get(&b"a".to_vec()), None, "earliest key should be evicted");
        assert_eq!(c.get(&b"b".to_vec()), Some(b"2".to_vec()));
        assert_eq!(c.get(&b"c".to_vec()), Some(b"3".to_vec()));
    }

    #[test]
    fn remove_works() {
        let mut c = lru(4);
        c.insert(b"k".to_vec(), b"v".to_vec());
        c.remove(&b"k".to_vec());
        assert_eq!(c.get(&b"k".to_vec()), None);
    }

    #[test]
    fn clear_empties() {
        let mut c = lru(4);
        c.insert(b"a".to_vec(), b"1".to_vec());
        c.insert(b"b".to_vec(), b"2".to_vec());
        c.clear();
        assert_eq!(c.get(&b"a".to_vec()), None);
        let (_, _, len, _) = c.stats();
        assert_eq!(len, 0);
    }

    #[test]
    fn stats_counts() {
        let mut c = lru(4);
        c.insert(b"a".to_vec(), b"1".to_vec());
        let _ = c.get(&b"a".to_vec()); // hit
        let _ = c.get(&b"x".to_vec()); // miss
        let (hits, misses, len, capacity) = c.stats();
        assert_eq!(hits, 1);
        assert_eq!(misses, 1);
        assert_eq!(len, 1);
        assert_eq!(capacity, 4);
    }

    #[test]
    fn default_policy_is_scan_resistant_twoq() {
        // Unknown policy name falls back to 2Q and still works.
        let mut c = build_cache(b"unknown-xyz", 4);
        c.insert(b"k".to_vec(), b"v".to_vec());
        assert_eq!(c.get(&b"k".to_vec()), Some(b"v".to_vec()));
    }
}
