// Rust calling the bridged Swift greeter across the C ABI.
use greeter_rust_client as greeter;

fn main() {
    let mut failures = 0;
    let mut check = |ok: bool, what: &str| {
        if !ok {
            eprintln!("FAIL: {what}");
            failures += 1;
        }
    };

    let hello = greeter::greeting("rust");
    println!("greeting(\"rust\")   = {hello}");
    check(hello == "Hello from Swift, rust!", "greeting");
    check(greeter::add(2, 40) == 42, "add");
    check(!greeter::isEven(7), "isEven");
    check(greeter::checksum(&[1, 2, 3, 4, 250]) == 9, "checksum");

    let metrics = greeter::measure("hi", 10.0);
    println!("measure.label      = {}", metrics.label);
    check(metrics.label == "HI", "measure struct");
    check(greeter::area(metrics.clone()) > 0.0, "area struct param");

    check(greeter::requireEven(42) == Ok(21), "requireEven ok");
    check(greeter::requireEven(7).is_err(), "requireEven err");
    check(greeter::parseNumber("19") == Ok(19), "parseNumber ok");
    check(greeter::parseNumber("nope").is_err(), "parseNumber err");

    if failures > 0 {
        eprintln!("FAIL: {failures} check(s)");
        std::process::exit(1);
    }
    println!("OK: Rust drove the bridged Swift greeter across the C ABI.");
}
