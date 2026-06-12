use core::fmt;

use crate::errno::Errno;
use crate::sys;

/// Write all bytes to the given fd; returns bytes written or error.
pub fn write(fd: u64, data: &[u8]) -> Result<usize, Errno> {
	let ret = unsafe {
		sys::syscall3(
			sys::Syscall::Write,
			fd as usize,
			data.as_ptr() as usize,
			data.len(),
		)
	};
	sys::ok(ret)
}

/// Read up to `buf.len()` bytes from the given fd.
pub fn read(fd: u64, buf: &mut [u8]) -> Result<usize, Errno> {
	let ret = unsafe {
		sys::syscall3(
			sys::Syscall::Read,
			fd as usize,
			buf.as_mut_ptr() as usize,
			buf.len(),
		)
	};
	sys::ok(ret)
}

pub struct FdWriter(pub u64);

impl fmt::Write for FdWriter {
	fn write_str(&mut self, s: &str) -> fmt::Result {
		let mut remaining = s.as_bytes();
		while !remaining.is_empty() {
			match write(self.0, remaining) {
				Ok(0) | Err(_) => return Err(fmt::Error),
				Ok(n) => remaining = &remaining[n..],
			}
		}
		Ok(())
	}
}

#[doc(hidden)]
pub fn _print(fd: u64, args: fmt::Arguments) {
	use fmt::Write;
	FdWriter(fd).write_fmt(args).ok();
}

/// Read one line from stdin (fd 0) into `buf`. Returns the slice without the
/// trailing newline, or `Err` on I/O failure.
pub fn read_line(buf: &mut [u8]) -> Result<&[u8], Errno> {
	let mut pos = 0;
	while pos < buf.len() {
		let n = read(0, &mut buf[pos..pos + 1])?;
		if n == 0 {
			break;
		}
		if buf[pos] == b'\n' {
			break;
		}
		pos += n;
	}
	Ok(&buf[..pos])
}

#[macro_export]
macro_rules! print {
    ($($arg:tt)*) => { $crate::io::_print(1, ::core::format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! println {
    ()            => { $crate::print!("\n") };
    ($($arg:tt)*) => { $crate::print!("{}\n", ::core::format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! eprint {
    ($($arg:tt)*) => { $crate::io::_print(2, ::core::format_args!($($arg)*)) };
}

#[macro_export]
macro_rules! eprintln {
    ()            => { $crate::eprint!("\n") };
    ($($arg:tt)*) => { $crate::eprint!("{}\n", ::core::format_args!($($arg)*)) };
}
