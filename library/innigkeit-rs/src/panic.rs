use core::fmt::Write;
use core::panic::PanicInfo;

use crate::io::FdWriter;

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
	let mut w = FdWriter(2);
	let _ = writeln!(w, "rust panic: {}", info);
	crate::process::exit(101);
}
