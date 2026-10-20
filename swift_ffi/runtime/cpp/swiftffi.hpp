// swiftffi.hpp — the hand-written C++ half of the bridge runtime, shared by
// every generated C++ binding (docs/bridge_v2.md). Header-only, C++17.
//
// Type mapping: Swift Int → int64_t, Int32 → int32_t, Double → double,
// Bool → bool, String → std::string, [UInt8] → std::vector<uint8_t>,
// @ExportedStruct → a generated C++ struct, Result<T, Error> →
// swiftffi::Result<T>, Lazy<T> → swiftffi::Lazy<T>, closures →
// std::function, @ExportedInterface → a generated abstract class (Swift-owned
// instances as RAII wrappers; consumer implementations via std::shared_ptr).

#ifndef SWIFT_FFI_SWIFTFFI_HPP
#define SWIFT_FFI_SWIFTFFI_HPP

#include <cstdint>
#include <cstring>
#include <functional>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <map>
#include <vector>

#include "swift_abi.h"

namespace swiftffi {

// --- Errors ----------------------------------------------------------------

/// A Swift error surfaced across the bridge (message only).
class SwiftError : public std::runtime_error {
public:
    explicit SwiftError(std::string message) : std::runtime_error(std::move(message)) {}
};

/// The bridged shape of Swift `throws` / `Result` returns.
template <typename T>
class Result {
public:
    static Result success(T value) { return Result(std::move(value)); }
    static Result failure(std::string message) { return Result(Failure{std::move(message)}); }

    bool ok() const { return has_value_; }
    explicit operator bool() const { return has_value_; }

    /// The success value; throws SwiftError when this is a failure.
    const T &value() const & {
        if (!has_value_) throw SwiftError(message_);
        return value_;
    }
    T &&value() && {
        if (!has_value_) throw SwiftError(message_);
        return std::move(value_);
    }

    const std::string &error() const { return message_; }

private:
    struct Failure {
        std::string message;
    };
    explicit Result(T value) : has_value_(true), value_(std::move(value)) {}
    explicit Result(Failure failure) : has_value_(false), message_(std::move(failure.message)) {}

    bool has_value_;
    T value_{};
    std::string message_;
};

template <>
class Result<void> {
public:
    static Result success() { return Result(true, {}); }
    static Result failure(std::string message) { return Result(false, std::move(message)); }
    bool ok() const { return ok_; }
    explicit operator bool() const { return ok_; }
    void value() const {
        if (!ok_) throw SwiftError(message_);
    }
    const std::string &error() const { return message_; }

private:
    Result(bool ok, std::string message) : ok_(ok), message_(std::move(message)) {}
    bool ok_;
    std::string message_;
};

// --- The blob wire encoding (swift_abi.h) ---------------------------------

namespace blob {

enum : int32_t {
    kVoid = 0,
    kInt = 1,
    kInt32 = 2,
    kDouble = 3,
    kBool = 4,
    kString = 5,
    kBytes = 6,
    kStruct = 7,
    kList = 8,
    kHandle = 9,
    kError = 10,
    kForeign = 11,
};

class Writer {
public:
    void i32(int32_t v) { append(&v, 4); }
    void i64(int64_t v) { append(&v, 8); }
    void f64(double v) { append(&v, 8); }
    void bytes(const void *data, size_t count) { append(data, count); }
    void header(int32_t tag, int32_t aux) {
        i32(tag);
        i32(aux);
    }
    /// A STRUCT/HANDLE/FOREIGN header: types are identified on the wire by
    /// NAME (aux is the name's byte length, the name follows).
    void type_header(int32_t tag, const std::string &name) {
        i32(tag);
        i32(static_cast<int32_t>(name.size()));
        bytes(name.data(), name.size());
    }
    const std::vector<uint8_t> &data() const { return out_; }
    std::vector<uint8_t> take() { return std::move(out_); }

private:
    void append(const void *data, size_t count) {
        const auto *p = static_cast<const uint8_t *>(data);
        out_.insert(out_.end(), p, p + count);
    }
    std::vector<uint8_t> out_;
};

class Reader {
public:
    Reader(const uint8_t *data, size_t size) : data_(data), size_(size) {}
    explicit Reader(const std::vector<uint8_t> &data) : Reader(data.data(), data.size()) {}

    int32_t i32() {
        int32_t v;
        take(&v, 4);
        return v;
    }
    int64_t i64() {
        int64_t v;
        take(&v, 8);
        return v;
    }
    double f64() {
        double v;
        take(&v, 8);
        return v;
    }
    std::vector<uint8_t> bytes(size_t count) {
        require(count);
        std::vector<uint8_t> v(data_ + cursor_, data_ + cursor_ + count);
        cursor_ += count;
        return v;
    }
    std::string string(size_t count) {
        require(count);
        std::string v(reinterpret_cast<const char *>(data_ + cursor_), count);
        cursor_ += count;
        return v;
    }
    bool done() const { return cursor_ >= size_; }

private:
    void take(void *out, size_t count) {
        require(count);
        std::memcpy(out, data_ + cursor_, count);
        cursor_ += count;
    }
    void require(size_t count) const {
        if (cursor_ + count > size_) throw SwiftError("bridge blob truncated");
    }
    const uint8_t *data_;
    size_t size_;
    size_t cursor_ = 0;
};

/// Reads one value header, returning its (tag, aux). STRUCT/HANDLE/FOREIGN
/// carry their type NAME after the header (aux is its byte length) — the
/// name is consumed (and discarded) here so field/payload reads follow
/// directly.
inline std::pair<int32_t, int32_t> skip_header(Reader &reader) {
    int32_t tag = reader.i32();
    int32_t aux = reader.i32();
    if ((tag == kStruct || tag == kHandle || tag == kForeign) && aux > 0) {
        (void)reader.bytes(static_cast<size_t>(aux));
    }
    return {tag, aux};
}

}  // namespace blob

// --- Typed traits (generated struct specializations join these) -------------

template <typename T>
struct traits;  // encode(Writer&, const T&) / decode(blob::Reader&) — specialized below

template <>
struct traits<int64_t> {
    static void encode(blob::Writer &w, int64_t v) {
        w.header(blob::kInt, 0);
        w.i64(v);
    }
    static int64_t decode(blob::Reader &r) {
        auto [tag, aux] = blob::skip_header(r);
        (void)aux;
        if (tag != blob::kInt) throw SwiftError("expected Int");
        return r.i64();
    }
};

template <>
struct traits<int32_t> {
    static void encode(blob::Writer &w, int32_t v) {
        w.header(blob::kInt32, 0);
        w.i64(v);
    }
    static int32_t decode(blob::Reader &r) {
        auto [tag, aux] = blob::skip_header(r);
        (void)aux;
        if (tag != blob::kInt32) throw SwiftError("expected Int32");
        return static_cast<int32_t>(r.i64());
    }
};

template <>
struct traits<double> {
    static void encode(blob::Writer &w, double v) {
        w.header(blob::kDouble, 0);
        w.f64(v);
    }
    static double decode(blob::Reader &r) {
        auto [tag, aux] = blob::skip_header(r);
        (void)aux;
        if (tag != blob::kDouble) throw SwiftError("expected Double");
        return r.f64();
    }
};

template <>
struct traits<bool> {
    static void encode(blob::Writer &w, bool v) {
        w.header(blob::kBool, 0);
        w.i64(v ? 1 : 0);
    }
    static bool decode(blob::Reader &r) {
        auto [tag, aux] = blob::skip_header(r);
        (void)aux;
        if (tag != blob::kBool) throw SwiftError("expected Bool");
        return r.i64() != 0;
    }
};

template <>
struct traits<std::string> {
    static void encode(blob::Writer &w, const std::string &v) {
        w.header(blob::kString, 0);
        w.i64(static_cast<int64_t>(v.size()));
        w.bytes(v.data(), v.size());
    }
    static std::string decode(blob::Reader &r) {
        auto [tag, aux] = blob::skip_header(r);
        (void)aux;
        if (tag != blob::kString && tag != blob::kError) throw SwiftError("expected String");
        auto count = static_cast<size_t>(r.i64());
        return r.string(count);
    }
};

template <>
struct traits<std::vector<uint8_t>> {
    static void encode(blob::Writer &w, const std::vector<uint8_t> &v) {
        w.header(blob::kBytes, 0);
        w.i64(static_cast<int64_t>(v.size()));
        w.bytes(v.data(), v.size());
    }
    static std::vector<uint8_t> decode(blob::Reader &r) {
        auto [tag, aux] = blob::skip_header(r);
        (void)aux;
        if (tag != blob::kBytes) throw SwiftError("expected [UInt8]");
        auto count = static_cast<size_t>(r.i64());
        return r.bytes(count);
    }
};

// Containers encode through the general LIST composite (the same convention
// the Swift Result/Array/Dictionary+Bridgeable conformances use): an i64
// element count, then each element's blob.
inline int64_t read_list_header(blob::Reader &r, const char *expected) {
    auto [tag, aux] = blob::skip_header(r);
    (void)aux;
    if (tag != blob::kList) throw SwiftError(std::string("expected ") + expected);
    return r.i64();
}

template <typename T>
struct traits<Result<T>> {
    static void encode(blob::Writer &w, const Result<T> &v) {
        w.header(blob::kList, 0);
        w.i64(2);
        traits<bool>::encode(w, !v.ok());
        if (v.ok()) {
            traits<T>::encode(w, v.value());
        } else {
            traits<std::string>::encode(w, v.error());
        }
    }
    static Result<T> decode(blob::Reader &r) {
        if (read_list_header(r, "Result") != 2) throw SwiftError("expected Result");
        if (traits<bool>::decode(r)) {
            return Result<T>::failure(traits<std::string>::decode(r));
        }
        return Result<T>::success(traits<T>::decode(r));
    }
};

// Swift Array<Element> <-> std::vector<T> (except std::vector<uint8_t>, which
// keeps the dedicated BYTES form above).
template <typename T>
struct traits<std::vector<T>> {
    static void encode(blob::Writer &w, const std::vector<T> &v) {
        w.header(blob::kList, 0);
        w.i64(static_cast<int64_t>(v.size()));
        for (const auto &item : v) traits<T>::encode(w, item);
    }
    static std::vector<T> decode(blob::Reader &r) {
        auto count = static_cast<size_t>(read_list_header(r, "Array"));
        std::vector<T> items;
        items.reserve(count);
        for (size_t i = 0; i < count; i++) items.push_back(traits<T>::decode(r));
        return items;
    }
};

// Swift Dictionary<Key, Value> <-> std::map<K, V>: alternating key/value
// pairs (unordered on the Swift side).
template <typename K, typename V>
struct traits<std::map<K, V>> {
    static void encode(blob::Writer &w, const std::map<K, V> &v) {
        w.header(blob::kList, 0);
        w.i64(static_cast<int64_t>(v.size()) * 2);
        for (const auto &[key, value] : v) {
            traits<K>::encode(w, key);
            traits<V>::encode(w, value);
        }
    }
    static std::map<K, V> decode(blob::Reader &r) {
        auto count = read_list_header(r, "Dictionary");
        if (count % 2 != 0) throw SwiftError("expected Dictionary");
        std::map<K, V> items;
        for (int64_t i = 0; i < count; i += 2) {
            auto key = traits<K>::decode(r);
            items.emplace(std::move(key), traits<V>::decode(r));
        }
        return items;
    }
};

template <typename T>
std::vector<uint8_t> encode(const T &value) {
    blob::Writer w;
    traits<T>::encode(w, value);
    return w.take();
}

template <typename T>
T decode(const std::vector<uint8_t> &bytes) {
    blob::Reader r(bytes);
    return traits<T>::decode(r);
}

/// If the blob is an ERROR blob, its message.
inline bool error_message(const std::vector<uint8_t> &bytes, std::string &message) {
    if (bytes.size() < 4) return false;
    int32_t tag;
    std::memcpy(&tag, bytes.data(), 4);
    if (tag != blob::kError) return false;
    blob::Reader r(bytes);
    message = traits<std::string>::decode(r);
    return true;
}

// --- Box draining (module entry points passed by the generated code) --------

struct BoxOps {
    int32_t (*len)(void *);
    void (*copy)(void *, void *);
    void (*release)(void *);
};

inline std::vector<uint8_t> take_box(void *box, const BoxOps &ops) {
    if (!box) return {};
    int32_t len = ops.len(box);
    std::vector<uint8_t> out(static_cast<size_t>(len));
    if (len > 0) ops.copy(box, out.data());
    ops.release(box);
    return out;
}

inline std::string take_string_box(void *box, const BoxOps &ops) {
    auto bytes = take_box(box, ops);
    return std::string(bytes.begin(), bytes.end());
}

/// Drains a throwing call's error box into a SwiftError.
[[noreturn]] inline void throw_error_box(void *box, const BoxOps &ops) {
    throw SwiftError(take_string_box(box, ops));
}

// --- Closures / dispatchers --------------------------------------------------

/// The consumer-side dispatcher: receives the raw argument-blob sequence,
/// returns the result blob (or throws; exceptions become ERROR blobs).
using Dispatcher = std::function<std::vector<uint8_t>(const std::vector<uint8_t> &)>;

namespace detail {

struct ClosureCtx {
    Dispatcher dispatcher;
    int refs = 1;
};

inline void closure_invoke(void *raw, const void *args, int64_t args_len,
                           bridge_buf *result_out, bridge_buf *error_out) {
    auto *ctx = static_cast<ClosureCtx *>(raw);
    try {
        const auto *data = static_cast<const uint8_t *>(args);
        std::vector<uint8_t> arg_bytes(data, data + args_len);
        auto result = ctx->dispatcher(arg_bytes);
        result_out->ptr = bridge_alloc(static_cast<int64_t>(result.size()));
        result_out->len = static_cast<int64_t>(result.size());
        if (!result.empty()) std::memcpy(result_out->ptr, result.data(), result.size());
    } catch (const std::exception &error) {
        blob::Writer w;
        std::string message = error.what();
        w.header(blob::kError, 0);
        w.i64(static_cast<int64_t>(message.size()));
        w.bytes(message.data(), message.size());
        auto blob_bytes = w.take();
        error_out->ptr = bridge_alloc(static_cast<int64_t>(blob_bytes.size()));
        error_out->len = static_cast<int64_t>(blob_bytes.size());
        std::memcpy(error_out->ptr, blob_bytes.data(), blob_bytes.size());
    }
}

inline void closure_retain(void *raw) {
    ++static_cast<ClosureCtx *>(raw)->refs;
}

inline void closure_release(void *raw) {
    auto *ctx = static_cast<ClosureCtx *>(raw);
    if (--ctx->refs <= 0) delete ctx;
}

}  // namespace detail

/// Owns a bridge_closure for the duration of a call (creation reference; the
/// Swift side retains for escaping captures).
class Closure {
public:
    explicit Closure(Dispatcher dispatcher) {
        auto *ctx = new detail::ClosureCtx{std::move(dispatcher)};
        closure_ = bridge_closure{ctx, detail::closure_invoke, detail::closure_retain,
                                  detail::closure_release};
    }
    ~Closure() { detail::closure_release(closure_.ctx); }
    Closure(const Closure &) = delete;
    Closure &operator=(const Closure &) = delete;

    const bridge_closure *get() const { return &closure_; }

private:
    bridge_closure closure_;
};

// --- Lazy --------------------------------------------------------------------

/// A deferred Swift value: the Swift-side computation runs on first `value()`
/// (then caches); the handle is released exactly once.
template <typename T>
class Lazy {
public:
    using GetFn = std::vector<uint8_t> (*)(void *);
    using ReleaseFn = void (*)(void *);

    Lazy(void *handle, GetFn get, ReleaseFn release)
        : handle_(handle), get_(get), release_(release) {}
    ~Lazy() { reset(); }
    Lazy(Lazy &&other) noexcept { *this = std::move(other); }
    Lazy &operator=(Lazy &&other) noexcept {
        reset();
        handle_ = other.handle_;
        get_ = other.get_;
        release_ = other.release_;
        cached_ = std::move(other.cached_);
        has_value_ = other.has_value_;
        other.handle_ = nullptr;
        return *this;
    }
    Lazy(const Lazy &) = delete;
    Lazy &operator=(const Lazy &) = delete;

    /// The value, computed in Swift on first access.
    const T &value() {
        if (!has_value_) {
            auto bytes = get_(handle_);
            cached_ = swiftffi::decode<T>(bytes);
            has_value_ = true;
            reset();
        }
        return cached_;
    }

private:
    void reset() {
        if (handle_) {
            release_(handle_);
            handle_ = nullptr;
        }
    }
    void *handle_ = nullptr;
    GetFn get_ = nullptr;
    ReleaseFn release_ = nullptr;
    T cached_{};
    bool has_value_ = false;
};

}  // namespace swiftffi

#endif  // SWIFT_FFI_SWIFTFFI_HPP
