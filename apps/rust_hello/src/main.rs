#![no_std]
#![no_main]

use innigkeit_rs::prelude::*;

#[unsafe(no_mangle)]
fn main() {
	println!("rust fr!");

	let ms = uptime_ms();
	println!("uptime: {} ms", ms);

	for (i, arg) in args().enumerate() {
		println!(
			"argv[{}] = {:?}",
			i,
			core::str::from_utf8(arg).unwrap_or("(invalid utf8)")
		);
	}
}
