#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &str| {
    let engine = mlatu_lib::Engine::new();
    _ = mlatu_lib::parse::rules(&engine, data);
    _ = mlatu_lib::parse::terms(&engine, data);
});
