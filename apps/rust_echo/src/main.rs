#![no_std]
#![no_main]

use core::net::Ipv4Addr;

use innigkeit_rs::net;
use innigkeit_rs::prelude::*;

#[unsafe(no_mangle)]
fn main() {
	let our_ip = Ipv4Addr::new(10, 0, 2, 15);
	if let Err(e) = net::set_ip(our_ip) {
		eprintln!("rust_echo: set_ip failed: {}", e);
		exit(1);
	}

	let port: u16 = args()
		.nth(1)
		.and_then(|s| core::str::from_utf8(s).ok())
		.and_then(parse_u16)
		.unwrap_or(7);

	let sock = match net::UdpSocket::bind(port) {
		Ok(s) => s,
		Err(e) => {
			eprintln!("rust_echo: bind port {} failed: {}", port, e);
			exit(1);
		}
	};

	println!("rust_echo: listening on {}:{}", our_ip, port);

	let mut buf = [0u8; 4096];
	let mut from = net::NetFrom {
		ip: [0; 4],
		port: 0,
		_pad: 0,
	};

	loop {
		match sock.recv_from(&mut from, &mut buf) {
			Ok(data) if !data.is_empty() => {
				let src = from.addr();
				// Echo the datagram back to the sender.
				if let Err(e) = sock.send_to(src, from.port, data) {
					eprintln!("rust_echo: send error: {}", e);
				}
			}
			Ok(_) => {}
			Err(e) if e.would_block() => {
				// No data yet, yield and try again.
				innigkeit_rs::process::yield_cpu();
			}
			Err(e) => {
				eprintln!("rust_echo: recv error: {}", e);
				exit(1);
			}
		}
	}
}

fn parse_u16(s: &str) -> Option<u16> {
	let mut n: u32 = 0;
	for b in s.bytes() {
		if !b.is_ascii_digit() {
			return None;
		}

		n = n.checked_mul(10)?.checked_add((b - b'0') as u32)?;
		if n > 0xFFFF {
			return None;
		}
	}

	Some(n as u16)
}
