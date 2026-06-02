//! Pool allocator: 8 power-of-2 size classes (16–2048 bytes) backed by
//! per-class free lists carved from mmap'd pages. Allocations larger than
//! 2048 bytes are mmap'd directly with a 16-byte header that stores the
//! mapping size so dealloc can call munmap correctly.
//!
//! All operations take a spinlock so the allocator is thread-safe.

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::ptr::null_mut;
use core::sync::atomic::{AtomicBool, Ordering};

use crate::sys;

const CLASSES: [usize; 8] = [16, 32, 64, 128, 256, 512, 1024, 2048];

fn class_for(size: usize) -> Option<usize> {
	CLASSES.iter().position(|&cs| size <= cs)
}

struct PoolAlloc {
	lock: AtomicBool,
	heads: UnsafeCell<[*mut u8; 8]>,
}

unsafe impl Sync for PoolAlloc {}
unsafe impl Send for PoolAlloc {}

impl PoolAlloc {
	const fn new() -> Self {
		Self {
			lock: AtomicBool::new(false),
			heads: UnsafeCell::new([null_mut(); 8]),
		}
	}

	#[inline]
	fn acquire(&self) {
		while self
			.lock
			.compare_exchange_weak(false, true, Ordering::Acquire, Ordering::Relaxed)
			.is_err()
		{
			core::hint::spin_loop();
		}
	}

	#[inline]
	fn release(&self) {
		self.lock.store(false, Ordering::Release);
	}

	// Called while lock is held.  Returns false if mmap failed.
	unsafe fn refill(&self, class: usize) -> bool {
		let block = CLASSES[class];
		let arena_size = if block >= 1024 { block * 8 } else { 4096 };
		let ret = unsafe {
			sys::syscall2(sys::Syscall::Mmap, arena_size, 3 /* RW */)
		};
		if ret < 0 {
			return false;
		}

		let base = ret as usize as *mut u8;
		let count = arena_size / block;
		let heads = unsafe { &mut *self.heads.get() };

		// Link all blocks into a free list (each block's first 8 bytes = next ptr).
		for i in 0..count {
			let blk = unsafe { base.add(i * block) };
			let next = if i + 1 < count {
				unsafe { base.add((i + 1) * block) }
			} else {
				null_mut()
			};
			unsafe { *(blk as *mut *mut u8) = next };
		}
		heads[class] = base;
		true
	}
}

unsafe impl GlobalAlloc for PoolAlloc {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		// Minimum size: must hold a free-list pointer (8 bytes on 64-bit).
		let size = layout.size().max(layout.align()).max(8);

		if let Some(cls) = class_for(size) {
			self.acquire();
			let heads = unsafe { &mut *self.heads.get() };
			if heads[cls].is_null() && !unsafe { self.refill(cls) } {
				self.release();
				return null_mut();
			}
			let block = heads[cls];
			heads[cls] = unsafe { *(block as *mut *mut u8) };
			self.release();
			block
		} else {
			// Large allocation: mmap with 16-byte header storing total size.
			let total = (size + 4095) & !4095; // page-align the payload
			let map_size = total + 16;
			let ret = unsafe { sys::syscall2(sys::Syscall::Mmap, map_size, 3) };
			if ret < 0 {
				return null_mut();
			}
			let header = ret as usize as *mut usize;
			unsafe { *header = map_size }; // store for dealloc
			unsafe { (header as *mut u8).add(16) }
		}
	}

	unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
		let size = layout.size().max(layout.align()).max(8);

		if let Some(cls) = class_for(size) {
			self.acquire();
			let heads = unsafe { &mut *self.heads.get() };
			unsafe { *(ptr as *mut *mut u8) = heads[cls] };
			heads[cls] = ptr;
			self.release();
		} else {
			let header = unsafe { ptr.sub(16) } as *mut usize;
			let map_size = unsafe { *header };
			let _ = unsafe { sys::syscall2(sys::Syscall::Munmap, header as usize, map_size) };
		}
	}
}

#[global_allocator]
static ALLOCATOR: PoolAlloc = PoolAlloc::new();
