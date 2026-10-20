// Shared "compiled mode" driver — see run.h. The greeter is compiled to native
// code and linked in; calls go through the generated idiomatic C++ bindings
// (which layer over the shared `swift_ffi_greeter_*` C ABI — the C layer is an
// implementation detail). The Linux and Windows compiled cells are a thin
// `main` over this.
#include "run.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "greeter_cpp.hpp"

namespace {

// A C++-implemented Counter passed *into* Swift: Swift calls back out through
// the generated foreign dispatcher.
class LocalCounter final : public greeter::Counter {
public:
    int64_t increment() override { return ++count_; }
    std::string label() override { return "local is at " + std::to_string(count_); }

private:
    int64_t count_ = 0;
};

}  // namespace

extern "C" int run_greeter_compiled(void) {
    int failures = 0;
    auto check = [&](bool ok, const char *what) {
        if (!ok) {
            std::fprintf(stderr, "FAIL: %s\n", what);
            ++failures;
        }
    };

    // The v1 surface: strings, scalars, bytes.
    std::string hello = greeter::greeting("compiled");
    std::printf("greeting(\"compiled\")        = %s\n", hello.c_str());
    check(hello == "Hello from Swift, compiled!", "greeting");

    int64_t sum = greeter::add(2, 40);
    std::printf("add(2, 40)                  = %lld\n", (long long)sum);
    check(sum == 42, "add");

    check(!greeter::isEven(7), "isEven");

    std::vector<uint8_t> data{1, 2, 3, 4, 250};
    check(greeter::checksum(data) == 9, "checksum");

    // Structs cross as field-wise copies.
    greeter::TextMetrics metrics = greeter::measure("hi", 10.0);
    std::printf("measure(\"hi\", 10).label     = %s\n", metrics.label.c_str());
    check(metrics.label == "HI", "measure");
    check(greeter::area(metrics) > 0, "area");

    // Interfaces: Swift-owned out, C++-implemented in.
    auto counter = greeter::makeCounter("native");
    counter->increment();
    std::string described = greeter::describe(counter);
    std::printf("describe(swift counter)     = %s\n", described.c_str());
    check(described == "counter says: native is at 1", "describe swift-owned");

    auto local = std::make_shared<LocalCounter>();
    local->increment();
    local->increment();
    std::string localDescribed = greeter::describe(local);
    std::printf("describe(local counter)     = %s\n", localDescribed.c_str());
    check(localDescribed == "counter says: local is at 2", "describe foreign");

    // Throwing bridges as swiftffi::Result.
    auto parsed = greeter::parseNumber("41");
    check(parsed.ok() && parsed.value() == 41, "parseNumber ok");
    auto notNumber = greeter::parseNumber("nope");
    check(!notNumber.ok(), "parseNumber err");

    // --- Bridge v2 ---------------------------------------------------------

    // Generics: real C++ templates, monomorphic per call site, erased to the
    // wire encoding underneath (no generics in the C ABI).
    check(greeter::choose<int64_t>(1, 2, false) == 1, "choose<int64_t>");
    check(greeter::choose<std::string>("a", "b", true) == "b", "choose<string>");
    // Containers cross generic positions via the LIST composite (the same
    // convention Swift's Result/Array/Dictionary+Bridgeable conformances use).
    check(greeter::choose<std::vector<int64_t>>({1, 2}, {3}, false) ==
              std::vector<int64_t>({1, 2}),
          "choose<vector<int64_t>>");
    check(greeter::choose<std::map<std::string, int64_t>>(
              {{"a", 1}, {"b", 2}}, {}, false) ==
              std::map<std::string, int64_t>({{"a", 1}, {"b", 2}}),
          "choose<map<string,int64_t>>");
    greeter::TextMetrics other{1.0, 2.0, "OTHER"};
    check(greeter::choose<greeter::TextMetrics>(metrics, other, true).label == "OTHER",
          "choose<TextMetrics>");

    // Callback closures (want b).
    int64_t tripled = greeter::transform(14, [](int64_t v) { return v * 3; });
    std::printf("transform(14, *3)           = %lld\n", (long long)tripled);
    check(tripled == 42, "transform closure");

    std::string listed = greeter::renderList(3, [](int64_t i) {
        return "item" + std::to_string(i);
    });
    std::printf("renderList(3)               = %s\n", listed.c_str());
    check(listed == "item1, item2, item3", "renderList closure");

    // Lazy<T> (want c): the Swift-side computation is deferred to the first
    // unwrap and runs exactly once.
    auto lazy = greeter::expensiveGreeting("cpp");
    const std::string &computed = lazy.value();
    std::printf("expensiveGreeting.value()   = %s\n", computed.c_str());
    check(computed.find("Expensively greeting cpp") == 0, "lazy value");
    check(computed == lazy.value(), "lazy caches");

    // Enums cross by raw value (string-raw -> std::string in C++).
    std::string toned = greeter::tonedGreeting("cpp", "cheerful");
    std::printf("tonedGreeting(cheerful)     = %s\n", toned.c_str());
    check(toned == "Hey hey, cpp!", "tonedGreeting enum");

    // Result<T, Error> as a first-class value (want a).
    check(greeter::describeOutcome(swiftffi::Result<int64_t>::success(7)) == "ok(7)",
          "describeOutcome ok");
    std::string errDescribed =
        greeter::describeOutcome(swiftffi::Result<int64_t>::failure("boom"));
    check(errDescribed.rfind("err(", 0) == 0, "describeOutcome err");

    if (failures) {
        std::fprintf(stderr, "FAIL: %d greeter call(s) returned unexpected values\n", failures);
        return 1;
    }
    std::printf("OK: the greeter ran as natively-linked Swift behind idiomatic C++.\n");
    return 0;
}
