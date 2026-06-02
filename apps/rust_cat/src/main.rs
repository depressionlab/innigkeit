#![no_std]
#![no_main]

extern crate alloc;

use alloc::vec::Vec;

use innigkeit_rs::prelude::*;

#[unsafe(no_mangle)]
fn main() {
	let mut argv = args();
	argv.next();

	let filename = match argv.next() {
		Some(f) => f,
		None => {
			eprintln!("usage: rust_cat <file>");
			exit(1);
		}
	};

	let file = match File::open(filename, OpenFlags::READ) {
		Ok(f) => f,
		Err(e) => {
			eprintln!("rust_cat: cannot open file: {}", e);
			exit(1);
		}
	};

	let mut buf: Vec<u8> = Vec::with_capacity(4096);
	buf.resize(4096, 0u8);

	loop {
		match file.read(&mut buf) {
			Ok(0) => break,
			Ok(n) => {
				if write(1, &buf[..n]).is_err() {
					break;
				}
			}
			Err(e) => {
				eprintln!("rust_cat: read error: {}", e);
				exit(1);
			}
		}
	}
}
