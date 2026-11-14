#include "probe.h"

#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct Base {
    virtual ~Base() = default;
};

struct Derived : Base {
    std::string name = "derived";
};

}  // namespace

int libcxx_probe(int count) {
    std::vector<std::string> parts;
    for (int i = 0; i < count; ++i) parts.push_back(std::to_string(i));
    std::string joined;
    for (const auto &part : parts) joined += part;
    std::unique_ptr<Base> base = std::make_unique<Derived>();
    auto *derived = dynamic_cast<Derived *>(base.get());
    if (derived == nullptr) return -1;
    try {
        throw std::runtime_error(joined + derived->name);
    } catch (const std::exception &error) {
        return static_cast<int>(std::string(error.what()).size());
    }
}
