use crate::errno::Errno;
use crate::sys;

pub fn exit(code: u8) -> ! {
	unsafe {
		sys::syscall1(sys::Syscall::ExitProcess, code as usize);
	}
	loop {
		unsafe {
			core::arch::asm!("hlt");
		}
	}
}

pub fn exit_thread() -> ! {
	unsafe {
		sys::syscall0(sys::Syscall::ExitThread);
	}
	loop {
		unsafe {
			core::arch::asm!("hlt");
		}
	}
}

pub fn uptime_ms() -> u64 {
	unsafe { sys::syscall0(sys::Syscall::UptimeMs) as u64 }
}

pub fn getpid() -> u64 {
	unsafe { sys::syscall0(sys::Syscall::GetPid) as u64 }
}

pub fn yield_cpu() {
	unsafe {
		sys::syscall0(sys::Syscall::Yield);
	}
}

/// Sleep until the absolute deadline (ms since boot).
pub fn sleep_until(deadline_ms: u64) {
	unsafe {
		sys::syscall1(sys::Syscall::NanosleepMs, deadline_ms as usize);
	}
}

/// Sleep for a relative duration in milliseconds.
pub fn sleep_ms(ms: u64) {
	let deadline = uptime_ms() + ms;
	sleep_until(deadline);
}

/// Iterator over process arguments, borrowing from the initial ELF stack.
pub struct Args {
	argv: *const *const u8,
	index: usize,
	count: usize,
}

impl Args {
	/// Number of arguments (including argv[0]).
	pub fn len(&self) -> usize {
		self.count
	}

	pub fn is_empty(&self) -> bool {
		self.count == 0
	}
}

impl Iterator for Args {
	type Item = &'static [u8];

	fn next(&mut self) -> Option<Self::Item> {
		if self.index >= self.count {
			return None;
		}
		let ptr = unsafe { *self.argv.add(self.index) };
		self.index += 1;
		if ptr.is_null() {
			return None;
		}
		// Walk to null terminator.
		let mut len = 0;
		unsafe {
			while *ptr.add(len) != 0 {
				len += 1;
			}
		}
		Some(unsafe { core::slice::from_raw_parts(ptr, len) })
	}
}

/// Iterate over process arguments.
pub fn args() -> Args {
	let base = crate::entry::raw_argc_argv();
	if base.is_null() {
		return Args {
			argv: core::ptr::null(),
			index: 0,
			count: 0,
		};
	}
	let argc = unsafe { *base };
	let argv = unsafe { base.add(1) as *const *const u8 };
	Args {
		argv,
		index: 0,
		count: argc,
	}
}

/// Matches the `SpawnSpec` layout expected by the kernel's `spawn` syscall
/// handler.
#[repr(C)]
struct SpawnSpec {
	path_ptr: *const u8,
	path_len: usize,
	argv_ptr: *const *const u8,
	argv_len: usize,
	/// Reserved / padding; must be zero.
	_pad: [usize; 4],
}

/// Spawn a child process. Returns the notify handle to wait on.
pub fn spawn(path: &[u8]) -> Result<u32, Errno> {
	let argv: [*const u8; 1] = [path.as_ptr()];
	let spec = SpawnSpec {
		path_ptr: path.as_ptr(),
		path_len: path.len(),
		argv_ptr: argv.as_ptr(),
		argv_len: 1,
		_pad: [0; 4],
	};
	let ret = unsafe { sys::syscall1(sys::Syscall::Spawn, &spec as *const SpawnSpec as usize) };
	sys::ok(ret).map(|h| h as u32)
}

/// Block until the child identified by `notify_handle` exits.  Returns its exit
/// status.
pub fn wait(notify_handle: u32) -> Result<u8, Errno> {
	let ret = unsafe { sys::syscall1(sys::Syscall::WaitProcess, notify_handle as usize) };
	sys::ok(ret).map(|s| s as u8)
}

/// Non-blocking wait. Returns `Err(Errno::EAGAIN)` if the process is still
/// running.
pub fn wait_nb(notify_handle: u32) -> Result<u8, Errno> {
	let ret = unsafe { sys::syscall1(sys::Syscall::WaitProcessNb, notify_handle as usize) };
	sys::ok(ret).map(|s| s as u8)
}

/// Send SIGKILL to the child identified by `notify_handle`.
pub fn kill(notify_handle: u32) -> Result<(), Errno> {
	let ret = unsafe { sys::syscall1(sys::Syscall::ProcessKill, notify_handle as usize) };
	sys::ok(ret).map(|_| ())
}
