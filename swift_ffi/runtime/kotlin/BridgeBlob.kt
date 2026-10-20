// The Kotlin half of the erased wire encoding ("blob") shared by every
// bridge — see bridge_ffi.h for the format. Little-endian, self-contained:
// generic arguments, Result values, struct copies, closure arguments, and
// Lazy payloads all cross the boundary in this encoding.
package swiftffi

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.reflect.KClass

object BridgeTags {
  const val VOID = 0
  const val INT = 1
  const val INT32 = 2
  const val DOUBLE = 3
  const val BOOL = 4
  const val STRING = 5
  const val BYTES = 6
  const val STRUCT = 7
  const val LIST = 8
  const val HANDLE = 9
  const val ERROR = 10
  const val FOREIGN = 11
}

class BlobWriter {
  private var buffer = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN)

  private fun ensure(count: Int) {
    if (buffer.remaining() < count) {
      val grown =
        ByteBuffer.allocate(maxOf(buffer.capacity() * 2, buffer.position() + count))
          .order(ByteOrder.LITTLE_ENDIAN)
      buffer.flip()
      grown.put(buffer)
      buffer = grown
    }
  }

  fun i32(value: Int): BlobWriter {
    ensure(4)
    buffer.putInt(value)
    return this
  }

  fun i64(value: Long): BlobWriter {
    ensure(8)
    buffer.putLong(value)
    return this
  }

  fun f64(value: Double): BlobWriter {
    ensure(8)
    buffer.putDouble(value)
    return this
  }

  fun bytes(value: ByteArray): BlobWriter {
    ensure(value.size)
    buffer.put(value)
    return this
  }

  fun header(tag: Int, aux: Int): BlobWriter = i32(tag).i32(aux)

  /** A STRUCT/HANDLE/FOREIGN header: types are identified on the wire by
   * NAME (aux is the name's byte length, the name follows). */
  fun typeHeader(tag: Int, name: String): BlobWriter {
    val bytes = name.toByteArray(Charsets.UTF_8)
    return i32(tag).i32(bytes.size).bytes(bytes)
  }

  fun toByteArray(): ByteArray {
    val out = ByteArray(buffer.position())
    buffer.duplicate().apply { flip() }.get(out)
    return out
  }
}

class BlobReader(bytes: ByteArray) {
  private val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

  fun i32(): Int = buffer.getInt()

  fun i64(): Long = buffer.getLong()

  fun f64(): Double = buffer.getDouble()

  fun bytes(count: Int): ByteArray {
    val out = ByteArray(count)
    buffer.get(out)
    return out
  }

  fun hasRemaining(): Boolean = buffer.hasRemaining()
}

/** A raw Swift interface handle inside an erased position; generated code
 * wraps it in the concrete Swift-owned wrapper class. */
class SwiftHandle(val bits: Long, val interfaceName: String)

/** An ERROR blob's decoded form (async completions branch on it). */
class SwiftErrorMessage(val message: String)

/** The codec for one generated `@ExportedStruct` data class. `encode` writes
 * the full blob (header included); `decodeFields` is called after the header
 * and field count were consumed. */
interface StructCodec<T : Any> {
  /** The struct's wire name (its Swift type name). */
  val name: String

  fun encode(writer: BlobWriter, value: T)

  fun decodeFields(reader: BlobReader): T
}

/** Struct codecs registered by generated bindings (keyed both ways). */
object BridgeCodecs {
  private val byClass = mutableMapOf<KClass<*>, StructCodec<*>>()
  private val byName = mutableMapOf<String, StructCodec<*>>()

  fun register(klass: KClass<*>, codec: StructCodec<*>) {
    byClass[klass] = codec
    byName[codec.name] = codec
  }

  fun forClass(klass: KClass<*>): StructCodec<*>? = byClass[klass]

  fun forName(name: String): StructCodec<*>? = byName[name]
}

object BridgeBlob {
  /** Dynamically encodes a bridgeable Kotlin value: Long → Swift Int,
   * Int → Int32, Double, Boolean, String, ByteArray, Unit, kotlin.Result,
   * or a registered struct. */
  @Suppress("UNCHECKED_CAST")
  fun encodeValue(writer: BlobWriter, value: Any?) {
    when (value) {
      null, Unit -> writer.header(BridgeTags.VOID, 0)
      is Long -> writer.header(BridgeTags.INT, 0).i64(value)
      is Int -> writer.header(BridgeTags.INT32, 0).i64(value.toLong())
      is Double -> writer.header(BridgeTags.DOUBLE, 0).i64(value.toRawBits())
      is Boolean -> writer.header(BridgeTags.BOOL, 0).i64(if (value) 1L else 0L)
      is String -> {
        val bytes = value.toByteArray(Charsets.UTF_8)
        writer.header(BridgeTags.STRING, 0).i64(bytes.size.toLong()).bytes(bytes)
      }
      is ByteArray -> writer.header(BridgeTags.BYTES, 0).i64(value.size.toLong()).bytes(value)
      is Result<*> ->
        // The general container encoding: a LIST of [isError, payload].
        value.fold(
          onSuccess = {
            writer.header(BridgeTags.LIST, 0).i64(2L)
            encodeValue(writer, false)
            encodeValue(writer, it)
          },
          onFailure = {
            writer.header(BridgeTags.LIST, 0).i64(2L)
            encodeValue(writer, true)
            encodeValue(writer, it.message ?: it.toString())
          },
        )
      is BridgeList -> {
        writer.header(BridgeTags.LIST, 0).i64(value.items.size.toLong())
        for (item in value.items) encodeValue(writer, item)
      }
      is List<*> -> {
        writer.header(BridgeTags.LIST, 0).i64(value.size.toLong())
        for (item in value) encodeValue(writer, item)
      }
      is Map<*, *> -> {
        writer.header(BridgeTags.LIST, 0).i64(value.size.toLong() * 2)
        for ((k, v) in value) {
          encodeValue(writer, k)
          encodeValue(writer, v)
        }
      }
      else -> {
        val codec =
          BridgeCodecs.forClass(value::class)
            ?: throw SwiftError("unbridgeable value of type ${value::class}")
        (codec as StructCodec<Any>).encode(writer, value)
      }
    }
  }

  /** An ERROR blob carrying `message` (a dispatcher's failure answer). */
  fun encodeError(message: String): ByteArray {
    val bytes = message.toByteArray(Charsets.UTF_8)
    return BlobWriter().header(BridgeTags.ERROR, 0).i64(bytes.size.toLong()).bytes(bytes).toByteArray()
  }

  fun encode(value: Any?): ByteArray {
    val writer = BlobWriter()
    encodeValue(writer, value)
    return writer.toByteArray()
  }

  /** Decodes one value: Long / Int / Double / Boolean / String / ByteArray /
   * Unit / kotlin.Result / a registered struct / SwiftHandle /
   * SwiftErrorMessage. */
  fun decodeValue(reader: BlobReader): Any? {
    val tag = reader.i32()
    val aux = reader.i32()
    return when (tag) {
      BridgeTags.VOID -> Unit
      BridgeTags.INT -> reader.i64()
      BridgeTags.INT32 -> reader.i64().toInt()
      BridgeTags.DOUBLE -> Double.fromBits(reader.i64())
      BridgeTags.BOOL -> reader.i64() != 0L
      BridgeTags.STRING -> String(reader.bytes(reader.i64().toInt()), Charsets.UTF_8)
      BridgeTags.BYTES -> reader.bytes(reader.i64().toInt())
      BridgeTags.STRUCT -> {
        val name = String(reader.bytes(aux), Charsets.UTF_8)
        val codec =
          BridgeCodecs.forName(name) ?: throw SwiftError("unknown struct '$name'")
        reader.i64() // field count (redundant with the codec)
        codec.decodeFields(reader)
      }
      BridgeTags.LIST -> {
        val count = reader.i64().toInt()
        BridgeList(List(count) { decodeValue(reader) })
      }
      BridgeTags.HANDLE -> {
        val name = String(reader.bytes(aux), Charsets.UTF_8)
        SwiftHandle(reader.i64(), name)
      }
      BridgeTags.FOREIGN -> {
        // A consumer-implemented instance's registry ref — not meaningful to
        // decode on the consumer side; surfaced as an opaque handle.
        val name = String(reader.bytes(aux), Charsets.UTF_8)
        SwiftHandle(reader.i64(), name)
      }
      BridgeTags.ERROR -> SwiftErrorMessage(String(reader.bytes(reader.i64().toInt()), Charsets.UTF_8))
      else -> throw SwiftError("unknown blob tag $tag")
    }
  }

  fun decode(bytes: ByteArray): Any? = decodeValue(BlobReader(bytes))

  /** Materializes a decoded LIST as `kotlin.Result` — the container encoding
   * is [isError, payload] (see the Swift Result+Bridgeable conformance). */
  fun asResult(value: Any?): Result<Any?> {
    val list = value as? BridgeList ?: throw SwiftError("expected Result, got $value")
    if (list.items.size != 2) throw SwiftError("expected Result, got list of ${list.items.size}")
    val isError = list.items[0] == true
    return if (isError) {
      Result.failure(SwiftError(list.items[1] as? String ?: "bridged error"))
    } else {
      Result.success(list.items[1])
    }
  }
}

/** A decoded LIST blob — the general ordered composite generic containers
 * encode through (Result = [isError, payload], Array = elements, Dictionary =
 * alternating key/value). Typed call sites materialize it (e.g.
 * [BridgeBlob.asResult]); generic call sites receive it as-is. */
class BridgeList(val items: List<Any?>)
