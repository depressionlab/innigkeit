use crate::errno::Errno;
use crate::sys;

pub struct OpenFlags(u32);

impl OpenFlags {
	pub const CREATE: OpenFlags = OpenFlags(1);
	pub const READ: OpenFlags = OpenFlags(0);
	pub const TRUNCATE: OpenFlags = OpenFlags(2);

	pub fn bits(self) -> u32 {
		self.0
	}
}

impl core::ops::BitOr for OpenFlags {
	type Output = Self;

	fn bitor(self, rhs: Self) -> Self {
		OpenFlags(self.0 | rhs.0)
	}
}

/// An open file descriptor.  Closed automatically on drop.
pub struct File {
	fd: u32,
}

impl File {
	/// Open a file by name.
	pub fn open(name: &[u8], flags: OpenFlags) -> Result<Self, Errno> {
		let ret = unsafe {
			sys::syscall3(
				sys::Syscall::FsOpen,
				name.as_ptr() as usize,
				name.len(),
				flags.bits() as usize,
			)
		};
		sys::ok(ret).map(|fd| File { fd: fd as u32 })
	}

	/// Read up to `buf.len()` bytes.  Returns 0 on EOF.
	pub fn read(&self, buf: &mut [u8]) -> Result<usize, Errno> {
		let ret = unsafe {
			sys::syscall3(
				sys::Syscall::FsRead,
				self.fd as usize,
				buf.as_mut_ptr() as usize,
				buf.len(),
			)
		};
		sys::ok(ret)
	}

	/// Write `data` to the file.
	pub fn write(&self, data: &[u8]) -> Result<usize, Errno> {
		let ret = unsafe {
			sys::syscall3(
				sys::Syscall::FsWrite,
				self.fd as usize,
				data.as_ptr() as usize,
				data.len(),
			)
		};
		sys::ok(ret)
	}

	/// Read the entire file into a `Vec<u8>`.
	pub fn read_to_vec(&self) -> Result<alloc::vec::Vec<u8>, Errno> {
		let mut out = alloc::vec::Vec::new();
		let mut buf = [0u8; 4096];
		loop {
			let n = self.read(&mut buf)?;
			if n == 0 {
				break;
			}
			out.extend_from_slice(&buf[..n]);
		}
		Ok(out)
	}

	pub fn fd(&self) -> u32 {
		self.fd
	}
}

impl Drop for File {
	fn drop(&mut self) {
		unsafe {
			sys::syscall1(sys::Syscall::FsClose, self.fd as usize);
		}
	}
}

/// Matches the `InitfsReadSpec` layout expected by the kernel.
#[repr(C)]
struct InitfsReadSpec {
	name_ptr: *const u8,
	name_len: usize,
	buf_ptr: *mut u8,
	buf_len: usize,
	offset: usize,
}

/// Read a file from the initfs (read-only, embedded in the kernel image).
pub fn initfs_read(name: &[u8], buf: &mut [u8], offset: usize) -> Result<usize, Errno> {
	let spec = InitfsReadSpec {
		name_ptr: name.as_ptr(),
		name_len: name.len(),
		buf_ptr: buf.as_mut_ptr(),
		buf_len: buf.len(),
		offset,
	};
	let ret = unsafe {
		sys::syscall1(
			sys::Syscall::InitfsRead,
			&spec as *const InitfsReadSpec as usize,
		)
	};
	sys::ok(ret)
}
