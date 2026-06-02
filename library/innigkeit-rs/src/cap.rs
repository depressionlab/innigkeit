use core::marker::PhantomData;

use crate::errno::Errno;
use crate::sys;

pub trait CapKind: private::Sealed {
	const CODE: u64;
}

mod private {
	pub trait Sealed {}
}

macro_rules! cap_kind {
	($name:ident, $code:expr) => {
		pub struct $name;
		impl private::Sealed for $name {}
		impl CapKind for $name {
			const CODE: u64 = $code;
		}
	};
}

cap_kind!(NotifyCap, 2);
cap_kind!(EndpointCap, 3);
cap_kind!(SecureVaultCap, 5);
cap_kind!(GpuBufferCap, 6);

/// An untyped kernel handle.
///
/// Does NOT close on drop; use `OwnedCap<T>` for RAII.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RawHandle(pub u32);

impl RawHandle {
	pub fn as_u32(self) -> u32 {
		self.0
	}
}

/// A borrowed, typed capability.  Does NOT close on drop.
#[derive(Clone, Copy)]
pub struct Cap<T: CapKind>(pub RawHandle, PhantomData<fn() -> T>);

impl<T: CapKind> Cap<T> {
	pub fn from_raw(h: RawHandle) -> Self {
		Cap(h, PhantomData)
	}

	pub fn raw(self) -> RawHandle {
		self.0
	}
}

/// An owned, typed capability.  Calls `cap_delete` on drop.
pub struct OwnedCap<T: CapKind> {
	handle: RawHandle,
	_kind: PhantomData<fn() -> T>,
}

impl<T: CapKind> OwnedCap<T> {
	pub fn from_raw(h: RawHandle) -> Self {
		OwnedCap {
			handle: h,
			_kind: PhantomData,
		}
	}

	pub fn as_cap(&self) -> Cap<T> {
		Cap::from_raw(self.handle)
	}

	pub fn raw(&self) -> RawHandle {
		self.handle
	}

	/// Relinquish ownership without closing.
	pub fn into_raw(self) -> RawHandle {
		let h = self.handle;
		core::mem::forget(self);
		h
	}
}

impl<T: CapKind> Drop for OwnedCap<T> {
	fn drop(&mut self) {
		unsafe {
			sys::syscall1(sys::Syscall::CapDelete, self.handle.as_u32() as usize);
		}
	}
}

/// Create a new kernel object of type `T`.  `arg` is type-specific (e.g., page
/// count for GpuBuffer, 0 for Notify/Endpoint).
pub fn create<T: CapKind>(arg: usize) -> Result<OwnedCap<T>, Errno> {
	let ret = unsafe { sys::syscall2(sys::Syscall::CapCreate, T::CODE as usize, arg) };
	sys::ok(ret).map(|h| OwnedCap::from_raw(RawHandle(h as u32)))
}

/// Copy capability, optionally restricting rights (16-bit bitmask).
pub fn copy<T: CapKind>(cap: Cap<T>, rights: u16) -> Result<OwnedCap<T>, Errno> {
	let ret = unsafe {
		sys::syscall2(
			sys::Syscall::CapCopy,
			cap.raw().as_u32() as usize,
			rights as usize,
		)
	};
	sys::ok(ret).map(|h| OwnedCap::from_raw(RawHandle(h as u32)))
}

/// Revoke all copies of a capability (increments generation counter).
pub fn revoke<T: CapKind>(cap: Cap<T>) -> Result<(), Errno> {
	let ret = unsafe { sys::syscall1(sys::Syscall::CapRevoke, cap.raw().as_u32() as usize) };
	sys::ok(ret).map(|_| ())
}

/// Invoke a capability (low-level; op and arg are kernel-defined).
pub fn invoke(handle: RawHandle, op: usize, arg: usize) -> Result<usize, Errno> {
	let ret = unsafe { sys::syscall3(sys::Syscall::CapInvoke, handle.as_u32() as usize, op, arg) };
	sys::ok(ret)
}

/// IPC message word 0 used to encode the signal bits for notify ops.
const NOTIFY_SIGNAL_OP: usize = 0;
const NOTIFY_WAIT_OP: usize = 1;

/// Signal a bitmask of bits on a Notify capability.
pub fn notify_signal(cap: Cap<NotifyCap>, bits: u64) -> Result<(), Errno> {
	invoke(cap.raw(), NOTIFY_SIGNAL_OP, bits as usize).map(|_| ())
}

/// Wait until at least one bit in `mask` is set; returns the set bits.
pub fn notify_wait(cap: Cap<NotifyCap>, mask: u64) -> Result<u64, Errno> {
	invoke(cap.raw(), NOTIFY_WAIT_OP, mask as usize).map(|v| v as u64)
}
