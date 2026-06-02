//! ELF entry point. Apps write a normal `fn main() { ... }` with no
//! attributes; the runtime handles argc/argv parsing and process exit.

use core::ptr::null_mut;
use core::sync::atomic::{AtomicPtr, Ordering};

static ARGC_ARGV_PTR: AtomicPtr<usize> = AtomicPtr::new(null_mut());

/// Return the raw ELF initial-stack pointer so `process::args()` can parse it.
pub(crate) fn raw_argc_argv() -> *const usize {
	ARGC_ARGV_PTR.load(Ordering::Relaxed)
}

// External reference to app's `main`
// Apps mark their `fn main()` with `#[no_mangle]` so the linker exposes it
// as the C symbol "main", which we call here.

unsafe extern "C" {
	unsafe fn main();
}

#[unsafe(naked)]
#[unsafe(no_mangle)]
unsafe extern "C" fn _start() -> ! {
	// Align stack to 16 bytes, pass original rsp (= argc/argv pointer) to
	// the real entry function in rdi, then call it.
	core::arch::naked_asm!(
		"xor  ebp, ebp",
		"mov  rdi, rsp",
		"and  rsp, -16",
		"call {entry}",
		entry = sym innigkeit_entry,
	);
}

extern "C" fn innigkeit_entry(argc_argv: *const usize) -> ! {
	ARGC_ARGV_PTR.store(argc_argv as *mut usize, Ordering::Relaxed);
	// Safety: the app must define `fn main()`.
	unsafe { main() };
	crate::process::exit(0);
}
