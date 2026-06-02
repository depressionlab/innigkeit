use core::fmt;

/// POSIX errno code returned by all fallible syscalls.
/// Negative kernel returns become `Err(Errno(n))` via [`crate::sys::ok`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Errno(pub i32);

impl Errno {
	pub const EACCES: Errno = Errno(13);
	pub const EAGAIN: Errno = Errno(11);
	pub const EBADF: Errno = Errno(9);
	pub const EBUSY: Errno = Errno(16);
	pub const EEXIST: Errno = Errno(17);
	pub const EFAULT: Errno = Errno(14);
	pub const EINTR: Errno = Errno(4);
	pub const EINVAL: Errno = Errno(22);
	pub const EIO: Errno = Errno(5);
	pub const ENOENT: Errno = Errno(2);
	pub const ENOMEM: Errno = Errno(12);
	pub const ENOSPC: Errno = Errno(28);
	pub const ENOSYS: Errno = Errno(38);
	pub const EPERM: Errno = Errno(1);
	pub const EWOULDBLOCK: Errno = Errno(11);

	pub fn would_block(self) -> bool {
		self.0 == 11
	}

	pub fn as_str(self) -> &'static str {
		match self.0 {
			1 => "EPERM",
			2 => "ENOENT",
			4 => "EINTR",
			5 => "EIO",
			9 => "EBADF",
			11 => "EAGAIN",
			12 => "ENOMEM",
			13 => "EACCES",
			14 => "EFAULT",
			16 => "EBUSY",
			17 => "EEXIST",
			22 => "EINVAL",
			28 => "ENOSPC",
			38 => "ENOSYS",
			_ => "EUNKNOWN",
		}
	}
}

impl fmt::Display for Errno {
	fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
		write!(f, "{} (errno {})", self.as_str(), self.0)
	}
}
