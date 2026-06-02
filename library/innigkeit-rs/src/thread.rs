use alloc::boxed::Box;

use crate::errno::Errno;
use crate::sys;

/// Thread entry trampoline
///
/// The kernel's `spawn_thread` syscall calls `entry(arg)` in a fresh thread.
/// We pass a heap-allocated `Box<dyn FnOnce()>` through the opaque `*mut ()`
/// arg.
extern "C" fn thread_trampoline(arg: usize) -> ! {
	let f_ptr = arg as *mut Box<dyn FnOnce()>;
	let f: Box<dyn FnOnce()> = unsafe { *Box::from_raw(f_ptr) };
	f();
	crate::process::exit_thread();
}

/// Spawn a new thread running `f`.
///
/// Returns the raw TID/handle on success.
pub fn spawn<F>(f: F) -> Result<u32, Errno>
where
	F: FnOnce() + Send + 'static,
{
	let boxed: Box<dyn FnOnce()> = Box::new(f);
	let arg = Box::into_raw(Box::new(boxed)) as usize;
	let ret = unsafe {
		sys::syscall2(
			sys::Syscall::SpawnThread,
			thread_trampoline as *const () as usize,
			arg,
		)
	};
	match sys::ok(ret) {
		Ok(tid) => Ok(tid as u32),
		Err(e) => {
			// Reclaim the allocation to avoid a leak on failure.
			unsafe {
				drop(Box::from_raw(arg as *mut Box<dyn FnOnce()>));
			}
			Err(e)
		}
	}
}

/// Hint the scheduler about this thread's preferred core class.
#[repr(u8)]
pub enum CoreHint {
	Unknown = 0,
	PCore = 1,
	ECore = 2,
}

pub fn set_core_hint(hint: CoreHint) {
	unsafe {
		sys::syscall1(sys::Syscall::ThreadSetHint, hint as usize);
	}
}
