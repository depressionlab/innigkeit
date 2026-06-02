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
