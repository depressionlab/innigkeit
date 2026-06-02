use core::cell::UnsafeCell;
use core::ops::{Deref, DerefMut};
use core::sync::atomic::{AtomicI32, Ordering};

use crate::sys;

#[inline]
fn futex_wait(addr: &AtomicI32, expected: i32) {
	unsafe {
		sys::syscall2(
			sys::Syscall::FutexWait,
			addr as *const AtomicI32 as usize,
			expected as usize,
		);
	}
}

#[inline]
fn futex_wake_one(addr: &AtomicI32) {
	unsafe {
		sys::syscall2(
			sys::Syscall::FutexWake,
			addr as *const AtomicI32 as usize,
			1,
		);
	}
}

// Drepper 3-state Mutex<T>
//
// State: 0 = unlocked, 1 = locked (no waiters), 2 = locked + waiters.

/// A mutual-exclusion lock using kernel futex.
///
/// Unlike `spin::Mutex`, this yields to the kernel when contended.
pub struct Mutex<T: ?Sized> {
	state: AtomicI32,
	data: UnsafeCell<T>,
}

// Safety: Mutex<T> provides mutual exclusion.
unsafe impl<T: Send + ?Sized> Send for Mutex<T> {}
unsafe impl<T: Send + ?Sized> Sync for Mutex<T> {}

impl<T> Mutex<T> {
	pub const fn new(val: T) -> Self {
		Mutex {
			state: AtomicI32::new(0),
			data: UnsafeCell::new(val),
		}
	}
}

impl<T: ?Sized> Mutex<T> {
	pub fn lock(&self) -> MutexGuard<'_, T> {
		// Fast path: transition 0 -> 1.
		if self
			.state
			.compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
			.is_ok()
		{
			return MutexGuard { mutex: self };
		}
		// Slow path: set state to 2 (locked + waiters), then block.
		loop {
			// Ensure state is 2 before sleeping so wake-up is guaranteed.
			let prev = self.state.swap(2, Ordering::Acquire);
			if prev == 0 {
				// We just acquired it (was unlocked, now marked 2 = locked+waiters).
				return MutexGuard { mutex: self };
			}
			futex_wait(&self.state, 2);
		}
	}

	/// Attempt to acquire the lock without blocking.
	pub fn try_lock(&self) -> Option<MutexGuard<'_, T>> {
		if self
			.state
			.compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
			.is_ok()
		{
			Some(MutexGuard { mutex: self })
		} else {
			None
		}
	}

	fn unlock(&self) {
		// If state was 2 (waiters exist), reset to 0 and wake one.
		if self.state.fetch_sub(1, Ordering::Release) != 1 {
			self.state.store(0, Ordering::Release);
			futex_wake_one(&self.state);
		}
	}
}

pub struct MutexGuard<'a, T: ?Sized> {
	mutex: &'a Mutex<T>,
}

impl<T: ?Sized> Deref for MutexGuard<'_, T> {
	type Target = T;

	fn deref(&self) -> &T {
		unsafe { &*self.mutex.data.get() }
	}
}

impl<T: ?Sized> DerefMut for MutexGuard<'_, T> {
	fn deref_mut(&mut self) -> &mut T {
		unsafe { &mut *self.mutex.data.get() }
	}
}

impl<T: ?Sized> Drop for MutexGuard<'_, T> {
	fn drop(&mut self) {
		self.mutex.unlock();
	}
}

/// Run a closure exactly once, even under concurrent calls.
pub struct Once {
	state: AtomicI32,
}

impl Default for Once {
	fn default() -> Self {
		Self::new()
	}
}

impl Once {
	pub const fn new() -> Self {
		Once {
			state: AtomicI32::new(0),
		}
	}

	pub fn call_once<F: FnOnce()>(&self, f: F) {
		if self.state.load(Ordering::Acquire) == 2 {
			return; // fast path: already done
		}

		// Race to become the runner.
		if self
			.state
			.compare_exchange(0, 1, Ordering::Acquire, Ordering::Relaxed)
			.is_ok()
		{
			f();
			self.state.store(2, Ordering::Release);
			// Wake all waiters.
			unsafe {
				sys::syscall2(
					sys::Syscall::FutexWake,
					&self.state as *const AtomicI32 as usize,
					i32::MAX as usize,
				);
			}
		} else {
			// Wait for the runner to finish.
			while self.state.load(Ordering::Acquire) != 2 {
				futex_wait(&self.state, 1);
			}
		}
	}
}
