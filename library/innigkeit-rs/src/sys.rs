use crate::errno::Errno;

pub enum Syscall {
	ExitThread,
	SpawnThread,
	Write,
	Read,
	Yield,
	Spawn,
	ExitProcess,
	WaitProcess,
	CapInvoke,
	CapCopy,
	CapMove,
	CapDelete,
	CapCreate,
	CapRevoke,
	Mmap,
	Munmap,
	FutexWait,
	FutexWake,
	VmemMap,
	VmemUnmap,
	FramebufferMap,
	InitfsRead,
	UptimeMs,
	BlkRead,
	KbdRead,
	NanosleepMs,
	FutexWaitTimeout,
	GetPid,
	WaitProcessNb,
	ProcessKill,
	BlkWrite,
	FsOpen,
	FsRead,
	FsWrite,
	FsClose,
	ThreadSetHint,
	EfiVarGet,
	EfiVarSet,
	BlkDiskSize,
	MouseRead,
	GpuFlush,
	NetSetIp,
	NetGetMac,
	NetUdpOpen,
	NetUdpSend,
	NetUdpRecv,
	NetUdpClose,
	NetPing,
	// TODO: 48..=53 are the TCP syscalls (not yet wrapped here). Discriminants
	// below are explicit so this enum stays append-only and in sync with
	// library/innigkeit/syscall.zig.
	/// (path_ptr, path_len, flags) -> fd. flags bit 0 = write (requires the
	/// storage entitlement).
	Open = 54,
	/// (fd) -> 0
	Close = 55,
	/// (fd, offset: i64, whence) -> new_offset. whence: 0=SET, 1=CUR, 2=END.
	Lseek = 56,
	/// (fd, stat_ptr) -> 0. Fills Stat{size: u64, kind: u8, _pad: [7]u8};
	/// kind: 0=file, 1=dir, 2=tty.
	Fstat = 57,
}

// x86_64 ABI: nr->rax, args->rdi rsi rdx r10 r8 r9; return in rax. Negative
// return = -(POSIX errno).

#[inline(always)]
pub unsafe fn syscall0(nr: Syscall) -> i64 {
	let ret: i64;
	unsafe {
		core::arch::asm!(
			"syscall",
			inlateout("rax") nr as i64 => ret,
			out("rcx") _, out("r11") _,
			options(nostack),
		);
	}
	ret
}

#[inline(always)]
pub unsafe fn syscall1(nr: Syscall, a0: usize) -> i64 {
	let ret: i64;
	unsafe {
		core::arch::asm!(
			"syscall",
			inlateout("rax") nr as i64 => ret,
			in("rdi") a0,
			out("rcx") _, out("r11") _,
			options(nostack),
		);
	}
	ret
}

#[inline(always)]
pub unsafe fn syscall2(nr: Syscall, a0: usize, a1: usize) -> i64 {
	let ret: i64;
	unsafe {
		core::arch::asm!(
			"syscall",
			inlateout("rax") nr as i64 => ret,
			in("rdi") a0,
			in("rsi") a1,
			out("rcx") _, out("r11") _,
			options(nostack),
		);
	}
	ret
}

#[inline(always)]
pub unsafe fn syscall3(nr: Syscall, a0: usize, a1: usize, a2: usize) -> i64 {
	let ret: i64;
	unsafe {
		core::arch::asm!(
			"syscall",
			inlateout("rax") nr as i64 => ret,
			in("rdi") a0,
			in("rsi") a1,
			in("rdx") a2,
			out("rcx") _, out("r11") _,
			options(nostack),
		);
	}
	ret
}

#[inline(always)]
pub unsafe fn syscall4(nr: Syscall, a0: usize, a1: usize, a2: usize, a3: usize) -> i64 {
	let ret: i64;
	unsafe {
		core::arch::asm!(
			"syscall",
			inlateout("rax") nr as i64 => ret,
			in("rdi") a0,
			in("rsi") a1,
			in("rdx") a2,
			in("r10") a3,
			out("rcx") _, out("r11") _,
			options(nostack),
		);
	}
	ret
}

#[inline(always)]
pub unsafe fn syscall5(nr: Syscall, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) -> i64 {
	let ret: i64;
	unsafe {
		core::arch::asm!(
			"syscall",
			inlateout("rax") nr as i64 => ret,
			in("rdi") a0,
			in("rsi") a1,
			in("rdx") a2,
			in("r10") a3,
			in("r8")  a4,
			out("rcx") _, out("r11") _,
			options(nostack),
		);
	}
	ret
}

/// Convert a raw kernel return value to `Result<usize, Errno>`.
#[inline]
pub fn ok(ret: i64) -> Result<usize, Errno> {
	if ret < 0 {
		Err(Errno(-ret as i32))
	} else {
		Ok(ret as usize)
	}
}
