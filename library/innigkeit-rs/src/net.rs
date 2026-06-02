use core::net::Ipv4Addr;

use crate::errno::Errno;
use crate::sys;

/// Set our IP address (big-endian packed).
pub fn set_ip(addr: Ipv4Addr) -> Result<(), Errno> {
	let ret = unsafe { sys::syscall1(sys::Syscall::NetSetIp, addr.to_bits().to_be() as usize) };
	sys::ok(ret).map(|_| ())
}

/// Read the 6-byte MAC address into `buf`.
pub fn get_mac(buf: &mut [u8; 6]) -> Result<(), Errno> {
	let ret = unsafe { sys::syscall1(sys::Syscall::NetGetMac, buf.as_mut_ptr() as usize) };
	sys::ok(ret).map(|_| ())
}

/// ICMP echo (ping). Returns round-trip time in ms on success.
pub fn ping(dst: Ipv4Addr, timeout_ms: u32) -> Result<u32, Errno> {
	let ret = unsafe {
		sys::syscall2(
			sys::Syscall::NetPing,
			dst.to_bits().to_be() as usize,
			timeout_ms as usize,
		)
	};
	sys::ok(ret).map(|v| v as u32)
}

/// Matches the `NetFrom` struct layout the kernel writes at `from_ptr`.
#[repr(C)]
pub struct NetFrom {
	pub ip: [u8; 4],
	pub port: u16,
	pub _pad: u16,
}

impl NetFrom {
	pub fn addr(&self) -> Ipv4Addr {
		Ipv4Addr::new(self.ip[0], self.ip[1], self.ip[2], self.ip[3])
	}
}

/// A bound UDP socket.  Closed automatically on drop.
pub struct UdpSocket {
	id: u32,
}

impl UdpSocket {
	/// Bind a UDP socket to `local_port`.
	pub fn bind(local_port: u16) -> Result<Self, Errno> {
		let ret = unsafe { sys::syscall1(sys::Syscall::NetUdpOpen, local_port as usize) };
		sys::ok(ret).map(|id| UdpSocket { id: id as u32 })
	}

	/// Send a datagram.
	pub fn send_to(&self, dst: Ipv4Addr, dst_port: u16, buf: &[u8]) -> Result<(), Errno> {
		let ret = unsafe {
			sys::syscall5(
				sys::Syscall::NetUdpSend,
				self.id as usize,
				dst.to_bits().to_be() as usize,
				dst_port as usize,
				buf.as_ptr() as usize,
				buf.len(),
			)
		};
		sys::ok(ret).map(|_| ())
	}

	/// Receive a datagram. Non-blocking: returns `Err(Errno::EAGAIN)` if no
	/// data.
	pub fn recv_from<'b>(&self, from: &mut NetFrom, buf: &'b mut [u8]) -> Result<&'b [u8], Errno> {
		let ret = unsafe {
			sys::syscall4(
				sys::Syscall::NetUdpRecv,
				self.id as usize,
				from as *mut NetFrom as usize,
				buf.as_mut_ptr() as usize,
				buf.len(),
			)
		};
		sys::ok(ret).map(|n| &buf[..n])
	}

	pub fn id(&self) -> u32 {
		self.id
	}
}

impl Drop for UdpSocket {
	fn drop(&mut self) {
		unsafe {
			sys::syscall1(sys::Syscall::NetUdpClose, self.id as usize);
		}
	}
}
